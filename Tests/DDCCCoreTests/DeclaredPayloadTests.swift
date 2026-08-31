import Testing
import Foundation
@testable import DDCCCore

/// Some applications install the bulk of themselves outside `~/Library` and
/// outside their own bundle. Epic Games Launcher is the measured case: 43 GB
/// of engine under `/Users/Shared/Epic Games` and a 21 GB download cache under
/// `/Users/Shared/UnrealEngine`, neither of which any evidence source could
/// see, so removing the launcher reported a fraction of what it left behind.
///
/// Every other source ENUMERATES — it lists what is on disk and attributes it.
/// This one DECLARES, from a curated table, which is a weaker kind of evidence
/// and why each entry names an exact directory rather than a parent to search.

@Test func declaredPayloadEmitsARootThatExists() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let payload = try tree.directory("Shared/Acme Engine")
        try tree.file("Shared/Acme Engine/big.bin", byteCount: 64)

        let source = DeclaredPayloadSource(
            table: ["com.acme.launcher": [payload.path(percentEncoded: false)]])
        let identity = BundleIdentity(
            bundleID: "com.acme.launcher", displayName: "Acme", bundleURL: nil, isPresent: true)

        let evidence = source.evidence(
            for: identity, in: ScanEnvironment(libraryURL: root.appending(path: "Library")))
        #expect(evidence.count == 1)
        #expect(evidence.first?.source == .declaredPayload)
        #expect(evidence.first?.claimedBy == "com.acme.launcher")
    }
}

/// The property that keeps a curated table from becoming a general bypass.
@Test func declaredPayloadEmitsNothingForAnAppNotInTheTable() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let payload = try tree.directory("Shared/Acme Engine")

        let source = DeclaredPayloadSource(
            table: ["com.acme.launcher": [payload.path(percentEncoded: false)]])
        let stranger = BundleIdentity(
            bundleID: "com.example.other", displayName: "Other", bundleURL: nil, isPresent: true)

        #expect(source.evidence(
            for: stranger,
            in: ScanEnvironment(libraryURL: root.appending(path: "Library"))).isEmpty)
    }
}

/// A declared path is a claim about what an app MIGHT install, so a machine
/// has only some of them. Emitting an absent one would put a phantom in the
/// footprint, which the assembler's own note calls out as the failure mode of
/// declared evidence.
@Test func declaredPayloadEmitsNothingForAPathThatIsNotOnDisk() throws {
    try withTempDirectory { root in
        let source = DeclaredPayloadSource(
            table: ["com.acme.launcher": ["/nonexistent/Acme Engine"]])
        let identity = BundleIdentity(
            bundleID: "com.acme.launcher", displayName: "Acme", bundleURL: nil, isPresent: true)

        #expect(source.evidence(
            for: identity,
            in: ScanEnvironment(libraryURL: root.appending(path: "Library"))).isEmpty)
    }
}

/// Every source in this file refuses Apple's namespace at the top. A curated
/// table must not become the one door that does not.
@Test func declaredPayloadRefusesAppleIdentitiesLikeEveryOtherSource() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let payload = try tree.directory("Shared/Something")

        let source = DeclaredPayloadSource(
            table: ["com.apple.something": [payload.path(percentEncoded: false)]])
        let apple = BundleIdentity(
            bundleID: "com.apple.something", displayName: "Something", bundleURL: nil, isPresent: true)

        #expect(source.evidence(
            for: apple,
            in: ScanEnvironment(libraryURL: root.appending(path: "Library"))).isEmpty)
    }
}

/// The two roots outside the home, which are what the declared mechanism was
/// built for. Measured 2026-08-29 on a reinstalled UE 5.8: 43 GB at the first,
/// 1.6 GB at the second. Epic's per-user paths are asserted separately, so
/// adding one there does not fail this.
@Test func theShippedTableDeclaresEpicsSharedPayloadRoots() {
    let roots = DeclaredPayloadSource.shippedTable["com.epicgames.EpicGamesLauncher"] ?? []
    #expect(roots.contains("/Users/Shared/Epic Games"))
    #expect(roots.contains("/Users/Shared/UnrealEngine"))
}

/// Each entry must name a directory specific enough that removing it cannot
/// take anything else with it. `/Users/Shared` itself is shared by every
/// account on the machine.
@Test func noDeclaredRootIsAWholeSharedOrHomeDirectory() {
    // Each of these is a directory many vendors share, or the user's own.
    // A declaration must name a directory one vendor owns.
    let forbidden = [
        "/", "/Users", "/Users/Shared", "/Applications", "/Library",
        "~", "~/Library", "~/Library/Caches", "~/Library/Application Support",
        "~/Library/Preferences", "~/Documents",
    ]
    for (bundleID, roots) in DeclaredPayloadSource.shippedTable {
        for declared in roots {
            #expect(forbidden.contains(declared) == false, "\(bundleID) declares \(declared)")
            // Absolute, or rooted at the home directory. A relative path would
            // resolve against whatever the working directory happened to be.
            #expect(
                declared.hasPrefix("/") || declared.hasPrefix("~/"),
                "\(bundleID) declares a relative path: \(declared)")
        }
    }
}

// MARK: - Assembly
//
// The source alone is not enough. A declared root sits outside the home, so it
// must pass two independent gates that both exist to stop exactly that: the
// allowlist of eight `~/Library` shelves, and `PathGuard`'s containment check
// against the scan root. Being offered for removal means clearing both.

private func apps(_ roots: [URL] = []) -> InstalledApps {
    InstalledApps.scan(roots: roots, maxDepth: 4, launchServices: { _ in false })
}

private func noClaimants(_ env: ScanEnvironment) -> ClaimantIndex {
    ClaimantIndex.build(
        installedApps: InstalledApps.scan(roots: [], launchServices: { _ in false }),
        environment: env, receipts: [], nonEnumerableSharedPaths: [], applicationGroups: { _ in [] })
}

@Test func aDeclaredPayloadOutsideTheHomeIsOfferedForRemoval() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        // Home is root/home, so root/Shared is genuinely outside it — the
        // shape of /Users/Shared against /Users/jrowe.
        let library = try tree.directory("home/Library")
        try tree.file("home/Library/Preferences/com.acme.launcher.plist", byteCount: 32)
        let payload = try tree.directory("Shared/Acme Engine")
        try tree.file("Shared/Acme Engine/engine.bin", byteCount: 1024)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.acme.launcher", displayName: "Acme", bundleURL: nil, isPresent: true)
        let payloadKey = Candidate.normalizedPathKey(for: payload)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: apps(), environment: env,
            claimants: noClaimants(env),
            caskPresence: nil,
            evidenceSources: [
                ShelfSource(),
                DeclaredPayloadSource(table: ["com.acme.launcher": [payload.path(percentEncoded: false)]]),
            ],
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            measure: { _ in 1024 })

        // Offered, which is the whole point: disclosure was not enough.
        #expect(footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == payloadKey })
        #expect(footprint.disclosedOutsideAllowlist.contains { $0.path == payloadKey } == false)

        // Positive control: the ordinary shelf evidence still came through,
        // so this is not a footprint that admits everything.
        #expect(footprint.items.count >= 2)
    }
}

/// The invariant the widening must not cost. An app with no table entry gets
/// exactly what it got before: nothing outside the eight allowlisted shelves.
@Test func anAppWithNoDeclaredPayloadIsStillConfinedToTheAllowlist() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("home/Library")
        try tree.file("home/Library/Preferences/com.example.other.plist", byteCount: 32)
        let payload = try tree.directory("Shared/Acme Engine")
        try tree.file("Shared/Acme Engine/engine.bin", byteCount: 1024)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.other", displayName: "Other", bundleURL: nil, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: apps(), environment: env,
            claimants: noClaimants(env),
            caskPresence: nil,
            evidenceSources: [
                ShelfSource(),
                // The table names a DIFFERENT app, so this identity earns no
                // bypass from its presence.
                DeclaredPayloadSource(table: ["com.acme.launcher": [payload.path(percentEncoded: false)]]),
            ],
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            measure: { _ in 1024 })

        let sharedKey = Candidate.normalizedPathKey(for: payload)
        #expect(footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == sharedKey } == false)
        // Positive control: it did produce its own shelf item.
        #expect(footprint.items.isEmpty == false)
    }
}

// MARK: - The composition the app actually runs
//
// The assembler's `evidenceSources` default listed DeclaredPayloadSource while
// UninstallCoordinator passed its own array that did not, so every test passed
// and the shipping app never consulted the table. A default argument is not a
// call site. This asserts the composition the sweep really uses.

@Test func theSweepsEvidenceSourcesIncludeDeclaredPayloads() {
    let env = ScanEnvironment(
        libraryURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library"))
    let sources = UninstallCoordinator.evidenceSources(
        shelves: ShelfSource.Snapshot(libraryKey: "", entriesByShelf: [:]),
        manifests: MessagingHostSource.snapshot(under: env.applicationSupportURL))

    #expect(sources.contains { $0 is DeclaredPayloadSource })
    // Positive control: the three that were already there are still there, so
    // this cannot pass by the list having been replaced wholesale.
    #expect(sources.contains { $0 is ContainerSource })
    #expect(sources.contains { $0 is ShelfSource })
    #expect(sources.contains { $0 is MessagingHostSource })
}

// MARK: - The engines
//
// Uninstalling an engine should take its downloads with it. Measured before
// this: removing Unity Hub reported 488 MB and left 2.5 GB, because ShelfSource
// matches an exact bundle id and Unity names its directories after the product
// -- `Caches/UnityHub`, not `Caches/com.unity3d.unityhub`.

@Test func uninstallingUnityHubClaimsTheEditorsItInstalled() {
    let roots = DeclaredPayloadSource.shippedTable["com.unity3d.unityhub"] ?? []
    // The containing folder, so every editor version goes with the Hub that
    // installed them rather than being left as orphans no app claims.
    #expect(roots.contains("/Applications/Unity"))
}

@Test func uninstallingGodotClaimsItsTemplatesAndCaches() {
    let roots = DeclaredPayloadSource.shippedTable["org.godotengine.godot"] ?? []
    #expect(roots.contains("~/Library/Application Support/Godot/export_templates"))
    #expect(roots.contains("~/Library/Caches/Godot"))
}

/// The hazard. `app_userdata` is 107 MB of save data written BY Godot games --
/// the one thing under that directory that is not Godot's to remove. It is
/// already denylisted for the Caches view; an uninstall must not reach it by
/// declaring the parent instead.
@Test func noEngineDeclarationReachesGodotsSaveData() {
    for (bundleID, roots) in DeclaredPayloadSource.shippedTable {
        for declared in roots {
            #expect(
                declared.contains("app_userdata") == false, "\(bundleID) declares \(declared)")
            // The parent would sweep app_userdata in with everything else.
            #expect(
                declared.hasSuffix("Application Support/Godot") == false,
                "\(bundleID) declares the whole Godot directory")
        }
    }
}

/// The same shape for Unity: `~/Library/Unity` holds the asset cache next to
/// `licenses`, which is the machine's activation.
@Test func noEngineDeclarationReachesTheUnityLicence() {
    for (bundleID, roots) in DeclaredPayloadSource.shippedTable {
        for declared in roots {
            #expect(declared.contains("licenses") == false, "\(bundleID) declares \(declared)")
            #expect(
                declared.hasSuffix("Library/Unity") == false,
                "\(bundleID) declares the whole ~/Library/Unity directory")
        }
    }
}

/// Project caches are not the engine's to remove. Uninstalling Godot must not
/// touch a .godot inside someone's project, nor Unity's Library, nor Unreal's
/// Intermediate -- those belong to the projects and outlive the engine.
@Test func noEngineDeclarationReachesAProjectCache() {
    let projectArtifacts = [".godot", "/Library", "Intermediate", "DerivedDataCache"]
    for (bundleID, roots) in DeclaredPayloadSource.shippedTable {
        for declared in roots {
            for artifact in projectArtifacts {
                #expect(
                    declared.hasSuffix(artifact) == false,
                    "\(bundleID) declares a project artifact: \(declared)")
            }
        }
    }
}

/// Epic's per-user side, measured on this machine with the launcher installed
/// and no engine: 103 MB of launcher data (1.6 GB once an engine is added),
/// 261 MB of logs, and the launch agent.
///
/// `~/Library/Logs` and `~/Library/LaunchAgents` are both outside the eight
/// allowlisted shelves, and `Preferences/Unreal Engine` is inside one but named
/// after the product rather than the bundle id -- the same miss as Unity's
/// `Caches/UnityHub`. None of it went with an uninstall before.
@Test func uninstallingEpicClaimsItsPerUserFilesToo() {
    let roots = DeclaredPayloadSource.shippedTable["com.epicgames.EpicGamesLauncher"] ?? []
    for expected in [
        "~/Library/Application Support/Epic",
        "~/Library/Application Support/Unreal Engine",
        "~/Library/Logs/Unreal Engine",
        "~/Library/Preferences/Unreal Engine",
    ] {
        #expect(roots.contains(expected), "missing \(expected)")
    }
}

/// Declared so it goes WITH the uninstall rather than surfacing as an orphan on
/// some later scan. The dead-artifact sweep is the backstop for an agent that
/// outlived its app; this is how it does not outlive it in the first place.
@Test func uninstallingEpicTakesItsLaunchAgent() {
    let roots = DeclaredPayloadSource.shippedTable["com.epicgames.EpicGamesLauncher"] ?? []
    #expect(roots.contains("~/Library/LaunchAgents/com.epicgames.launcher.plist"))
}
