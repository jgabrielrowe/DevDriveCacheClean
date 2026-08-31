import Testing
import Foundation
@testable import DDCCCore

// MARK: - Fixture helpers

/// Wraps a cask array as the JWS envelope `CaskIndex.load` expects — the
/// cask JSON lives inside `payload` as a *string*, not as nested JSON. Same
/// shape as `CaskIndexTests`' own helper; both are file-private, and this
/// file needs one because the assembler consumes `CaskIndex` directly rather
/// than through a `FootprintSource`.
private func writeCaskFixture(_ casks: String, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: ["payload": casks, "signatures": []])
    try data.write(to: url)
}

/// Creates a minimal `.app` bundle that `InstalledApps.scan` can read an
/// identifier out of. Kept to one plist and no payload so the fixture trees
/// in this file stay cheap — the suite budget is measured in whole seconds
/// and one real-machine sweep was already trimmed for costing 45% of it.
@discardableResult
private func makeAppBundle(
    _ tree: FixtureTree, at relativePath: String, bundleID: String, displayName: String
) throws -> URL {
    let bundleURL = try tree.directory(relativePath)
    let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": displayName]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try tree.directory(relativePath + "/Contents")
    try data.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    return bundleURL
}

/// An `InstalledApps` whose disk half comes from a fixture tree and whose
/// Launch Services half is whatever the test says it is. Both halves matter
/// to gate (a): `byID` is the scan snapshot `ClaimantIndex` counts over,
/// `isInstalled` is the live probe that can still veto a reclaim.
private func installedApps(
    scanning roots: [URL], launchServicesKnows known: Set<String> = []
) -> InstalledApps {
    InstalledApps.scan(roots: roots, maxDepth: 4, launchServices: { known.contains($0) })
}

private func emptyClaimants(_ env: ScanEnvironment) -> ClaimantIndex {
    ClaimantIndex.build(
        installedApps: InstalledApps.scan(roots: [], launchServices: { _ in false }),
        environment: env, receipts: [], nonEnumerableSharedPaths: [], applicationGroups: { _ in [] })
}

/// A footprint's items minus the app's own bundle.
///
/// Bundle removal made every present identity's `.app` an item,
/// so a test about what an app *left behind* now sees one extra row that has
/// nothing to do with claims, retention or the allowlist. Named rather than
/// inlined, so it is obvious at each call site that the assertion is about
/// leftovers and not a filter hiding a leak — `nothingOutsideTheAllowlistedRootsIsEverEmitted`
/// is what pins the bundle itself.
private func leftovers(of footprint: AppFootprint) -> [FootprintItem] {
    footprint.items.filter { !$0.sources.contains(.appBundle) }
}

private func leftoverBytes(of footprint: AppFootprint) -> Int64 {
    leftovers(of: footprint).reduce(Int64(0)) { $0 + $1.sizeBytes }
}

// MARK: - The allowlist invariant

/// The invariant that replaces a growing denylist table with one assertion.
///
/// The bundle id here is literally `Documents` — chosen to collide with the
/// name of a user-data directory, so every name-keyed source in the feature
/// (`ShelfSource`'s five shelves, `ContainerSource`'s two container roots)
/// matches something, and a cask declares `~/Documents` outright. If any one
/// of the assembler's stages leaked, this is the shape that leaks first.
///
/// The expected roots are spelled out here rather than read from
/// `FootprintAssembler.allowlistedRootNames`, so widening that constant
/// cannot silently widen the test that guards it.
@Test func nothingOutsideTheAllowlistedRootsIsEverEmitted() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try tree.file("Documents/precious.txt", byteCount: 4096)
        // The escape route the lexical assertion below cannot see: an
        // allowlisted-looking ancestor that is a symlink out of `~/Library`,
        // with a declared path *inside* it that is not itself a symlink. Its
        // key satisfies the prefix test; its resolved location is `~/Documents`.
        try tree.file("Documents/leak/hostage.txt", byteCount: 4096)
        try tree.directory("Library/Application Support")
        try tree.symlink(
            "Library/Application Support/Documents", to: root.appendingPathComponent("Documents"))
        try tree.file("Library/Containers/Documents/marker", byteCount: 16)
        try tree.file("Library/Preferences/Documents.plist", byteCount: 16)
        try tree.file("Library/Caches/Documents/entry", byteCount: 16)
        try tree.file("Library/LaunchAgents/Documents.plist", byteCount: 16)
        let bundleURL = try makeAppBundle(
            tree, at: "Applications/Documents.app", bundleID: "Documents", displayName: "Documents")

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "documents",
            "artifacts": [
              { "app": ["Documents.app"] },
              { "zap": [{ "trash": [
                  "\(root.path)/Documents",
                  "\(library.path)/LaunchAgents/Documents.plist",
                  "\(library.path)/Caches/Documents",
                  "\(library.path)/Application Support/Documents/leak",
                  "\(bundleURL.path)"
              ] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let apps = installedApps(scanning: [root.appendingPathComponent("Applications")])
        let identity = BundleIdentity(
            bundleID: "Documents", displayName: "Documents", bundleURL: bundleURL, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: apps, environment: env,
            claimants: emptyClaimants(env), caskIndex: CaskIndex.load(from: caskURL),
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let allowedRoots = [
            "Containers", "Group Containers", "Application Support", "Application Scripts",
            "Preferences", "Caches", "HTTPStorages", "Saved Application State",
        ].map { Candidate.normalizedPathKey(for: library.appendingPathComponent($0, isDirectory: true)) }

        // Positive control: the invariant is only meaningful if the assembler
        // actually produced something. A stage that silently returns nothing
        // also satisfies "nothing outside the allowlist".
        #expect(!footprint.items.isEmpty)

        // The one path allowed outside the allowlist, since bundle removal
        // shipped : the identity's own `.app`. It is exempt from
        // the allowlist because the allowlist describes `~/Library` shelves
        // and the bundle is in `/Applications` — but it is exempt from
        // nothing else, so the exemption is stated as an equality against the
        // one path the identity names rather than as a hole the loop skips.
        // Anything else escaping via `.appBundle` fails here.
        let bundleItems = (footprint.items + footprint.retained)
            .filter { $0.sources.contains(.appBundle) }
        #expect(bundleItems.map { Candidate.normalizedPathKey(for: $0.path) } == [
            Candidate.normalizedPathKey(for: bundleURL)
        ])
        // And it is never retained: no claimant concept applies to an app's
        // own bundle, so it can only ever be offered or refused.
        #expect(!footprint.retained.contains { $0.sources.contains(.appBundle) })

        let allowlisted = (footprint.items + footprint.retained)
            .filter { !$0.sources.contains(.appBundle) }
        #expect(!allowlisted.isEmpty, "every item was the bundle; the allowlist loop proves nothing")

        for item in allowlisted {
            let key = Candidate.normalizedPathKey(for: item.path)
            #expect(
                allowedRoots.contains { key.hasPrefix($0 + "/") },
                "escaped the allowlist: \(key)")
        }

        // The same invariant at the location the filesystem actually uses.
        // The lexical loop above is satisfied by a path whose ancestor is a
        // symlink out of `~/Library`, because it only ever sees the string;
        // `PathGuard` then resolves that chain and judges containment against
        // the *home* directory, so nothing else asks where the path really
        // is. Both sides are resolved with the same expression — a fixture
        // home under `NSTemporaryDirectory()` sits at `/var/folders/...`,
        // where `/var` is a symlink, so comparing a resolved path against a
        // lexical root rejects every path in this suite.
        let resolvedRoots = allowedRoots.map {
            Candidate.normalizedPathKey(
                for: URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath())
        }
        for item in allowlisted {
            let resolved = Candidate.normalizedPathKey(
                for: item.path.standardizedFileURL.resolvingSymlinksInPath())
            #expect(
                resolvedRoots.contains { resolved.hasPrefix($0 + "/") },
                "escaped the allowlist once resolved: \(resolved)")
        }

        let emitted = Set(allowlisted.map { Candidate.normalizedPathKey(for: $0.path) })
        #expect(!emitted.contains(Candidate.normalizedPathKey(for: root.appendingPathComponent("Documents"))))
        #expect(!emitted.contains(Candidate.normalizedPathKey(
            for: library.appendingPathComponent("LaunchAgents/Documents.plist"))))
        // The cask declares the bundle path too. It must not reach an item by
        // *that* route — only as the identity's own bundle, asserted above —
        // because a cask-declared `/Applications` path is exactly the
        // "receipt and cask manifests name paths everywhere" case the
        // allowlist exists to stop.
        #expect(!emitted.contains(Candidate.normalizedPathKey(for: bundleURL)))
        #expect(!emitted.contains(Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Documents/leak"))))
    }
}

/// Receipt manifests routinely name `/Applications` and `/Library` paths.
/// They are counted and disclosed — the honest number includes them — but
/// never offered for removal, because removing them needs privileges this
/// engine does not take and bundle removal has not shipped.
@Test func receiptPathsOutsideTheAllowlistAreDisclosedButNotOffered() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.file("Library/Preferences/com.example.pkgapp.plist", byteCount: 32)

        let env = ScanEnvironment(libraryURL: library)
        let receipt = Receipt(packageID: "com.example.pkgapp", installPrefix: "/", bomURL: nil)
        let insideKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/PkgApp"))
        try tree.file("Library/Application Support/PkgApp/data", byteCount: 64)

        let identity = BundleIdentity(
            bundleID: "com.example.pkgapp", displayName: "PkgApp", bundleURL: nil, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in
                ["/Applications/PkgApp.app", "/Library/PrivilegedHelperTools/com.example.pkgapp", insideKey]
            })

        let offered = Set((footprint.items + footprint.retained).map { Candidate.normalizedPathKey(for: $0.path) })
        #expect(!offered.contains("/Applications/PkgApp.app"))
        #expect(!offered.contains("/Library/PrivilegedHelperTools/com.example.pkgapp"))
        // The one receipt path that *is* inside the allowlist is still offered:
        // this refusal is about location, not about receipts.
        #expect(offered.contains(insideKey))

        let disclosed = Set(footprint.disclosedOutsideAllowlist.map(\.path))
        #expect(disclosed.contains("/Applications/PkgApp.app"))
        #expect(disclosed.contains("/Library/PrivilegedHelperTools/com.example.pkgapp"))
        #expect(footprint.disclosedOutsideAllowlist.allSatisfy { $0.source == .receipt(packageID: "com.example.pkgapp") })
    }
}

// MARK: - Whole-assembly refusals

/// A running app's data is being written *right now*. Removing a live
/// process's containers and preferences destroys state it holds open and
/// will rewrite, and the app running is itself direct evidence that it is
/// not gone. The refusal is total, not per-item: a partial footprint of a
/// live app is an invitation to delete half of it.
@Test func aRunningAppsFootprintIsRefusedEntirely() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.file("Library/Containers/com.example.live/marker", byteCount: 128)
        try tree.file("Library/Preferences/com.example.live.plist", byteCount: 128)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.live", displayName: "Live", bundleURL: nil, isPresent: true)

        let running = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in true })

        #expect(running.items.isEmpty)
        #expect(running.retained.isEmpty)
        #expect(running.reclaimableBytes == 0)
        #expect(running.refusal == .appIsRunning)

        // Positive control: the same fixture, not running, does produce a
        // footprint — so the refusal above is the running check and not an
        // empty fixture.
        let stopped = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })
        #expect(stopped.items.count == 2)
        #expect(stopped.refusal == nil)
    }
}

@Test func anAppWithNoEvidenceProducesAnEmptyFootprint() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.file("Library/Preferences/com.other.app.plist", byteCount: 32)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.ghost", displayName: "Ghost", bundleURL: nil, isPresent: false)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        #expect(footprint.items.isEmpty)
        #expect(footprint.retained.isEmpty)
        #expect(footprint.reclaimableBytes == 0)
        #expect(footprint.refusal == nil)
    }
}

// MARK: - Arithmetic of the retain-until-last rule

/// `reclaimableBytes` sums `items` only. A retained item's bytes are
/// disclosed on the row but excluded from the headline figure — that
/// exclusion *is* the retain-until-last rule, expressed as arithmetic.
@Test func reclaimableBytesExcludeRetainedSharedItems() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.file("Library/Preferences/com.example.one.plist", byteCount: 100)
        try tree.file("Library/Group Containers/TEAMAAAAAA.com.shared/blob", byteCount: 9000)

        let appsRoot = root.appendingPathComponent("Applications")
        let oneURL = try makeAppBundle(
            tree, at: "Applications/One.app", bundleID: "com.example.one", displayName: "One")
        try makeAppBundle(
            tree, at: "Applications/Two.app", bundleID: "com.example.two", displayName: "Two")

        let env = ScanEnvironment(libraryURL: library)
        let apps = installedApps(scanning: [appsRoot])
        // Both apps hold the same group entitlement, so removing One leaves
        // Two as a remaining claimant.
        let groups: @Sendable (URL) -> Set<String> = { _ in ["TEAMAAAAAA.com.shared"] }
        let claimants = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [],
            nonEnumerableSharedPaths: [], applicationGroups: groups)

        let identity = BundleIdentity(
            bundleID: "com.example.one", displayName: "One", bundleURL: oneURL, isPresent: true)
        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: apps, environment: env,
            claimants: claimants, caskPresence: nil,
            applicationGroups: groups, isRunning: { _ in false })

        let retained = try #require(footprint.retained.first)
        #expect(footprint.retained.count == 1)
        #expect(retained.retainedFor.contains("com.example.two"))
        #expect(retained.sizeBytes >= 9000)
        #expect(!retained.isDeletable)

        let itemBytes = footprint.items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        #expect(footprint.reclaimableBytes == itemBytes)
        #expect(footprint.reclaimableBytes < retained.sizeBytes)
    }
}

/// Two sources finding the same directory is corroboration, not a second
/// directory. Dedup is by `Candidate.normalizedPathKey(for:)` — this
/// project's one path-key derivation — and the merge must keep both
/// sources, because dropping one loses the evidence that made the
/// attribution strong.
@Test func aPathFoundByTwoSourcesAppearsOnceCarryingBothSources() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let containerPath = try tree.directory("Library/Containers/com.example.dual")
        try tree.file("Library/Containers/com.example.dual/blob", byteCount: 256)
        let bundleURL = try makeAppBundle(
            tree, at: "Applications/Dual.app", bundleID: "com.example.dual", displayName: "Dual")

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "dual",
            "artifacts": [
              { "app": ["Dual.app"] },
              { "zap": [{ "trash": ["\(containerPath.path)"] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.dual", displayName: "Dual", bundleURL: bundleURL, isPresent: true)
        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskIndex: CaskIndex.load(from: caskURL),
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let key = Candidate.normalizedPathKey(for: containerPath)
        let matches = footprint.items.filter { Candidate.normalizedPathKey(for: $0.path) == key }
        #expect(matches.count == 1)
        let item = try #require(matches.first)
        #expect(item.sources.contains(.container))
        #expect(item.sources.contains(.cask(token: "dual")))
    }
}

// MARK: - Gate (a): reclaim requires positive confirmation, never an absence

/// `ClaimantIndex` counts group-container claimants over `InstalledApps
/// .byID` — the disk scan — so an app in `~/Downloads`, `/Users/Shared`,
/// `/opt` or on another volume writes into this user's `Group Containers`
/// and contributes no claimant at all. An empty `remainingClaimants` over
/// `.scannedInstalledApps` therefore proves only "no *scanned* claimant
/// remains", never "the last claimant is gone".
///
/// So the assembler asks the live, Launch-Services-backed
/// `InstalledApps.isInstalled(_:)` before collecting, and any positive
/// answer retains. Here the group is `TEAMAAAAAA.com.shared`; nothing but
/// the app being removed claims it in the scan, but Launch Services knows
/// `com.shared` — an app the scan's roots never reached. It must retain.
@Test func anEmptyScannedClaimantSetDoesNotByItselfReleaseAGroupContainer() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.file("Library/Group Containers/TEAMAAAAAA.com.shared/blob", byteCount: 4096)
        let appsRoot = root.appendingPathComponent("Applications")
        let soleURL = try makeAppBundle(
            tree, at: "Applications/Sole.app", bundleID: "com.example.sole", displayName: "Sole")

        let env = ScanEnvironment(libraryURL: library)
        let groups: @Sendable (URL) -> Set<String> = { _ in ["TEAMAAAAAA.com.shared"] }
        let identity = BundleIdentity(
            bundleID: "com.example.sole", displayName: "Sole", bundleURL: soleURL, isPresent: true)

        func footprint(launchServicesKnows known: Set<String>) -> AppFootprint {
            let apps = installedApps(scanning: [appsRoot], launchServicesKnows: known)
            let claimants = ClaimantIndex.build(
                installedApps: apps, environment: env, receipts: [],
                nonEnumerableSharedPaths: [], applicationGroups: groups)
            return FootprintAssembler.assemble(
                identity: identity, installedApps: apps, environment: env,
                claimants: claimants, caskPresence: nil,
            applicationGroups: groups, isRunning: { _ in false })
        }

        // Launch Services vouches for the team-stripped group id, which no
        // scanned app accounts for. Retain.
        let vetoed = footprint(launchServicesKnows: ["com.shared"])
        // Leftovers only: the identity is present, so its bundle is now an
        // item too, and this test is about the group container's claim.
        #expect(leftovers(of: vetoed).isEmpty)
        let retained = try #require(vetoed.retained.first)
        #expect(retained.retainedFor.contains("com.shared"))
        #expect(leftoverBytes(of: vetoed) == 0)

        // Nothing else vouches for it, so it is collectable — but the row
        // still carries the caveat that "no remaining claimant" was only
        // ever checked against the scanned population.
        let collectable = footprint(launchServicesKnows: [])
        #expect(collectable.retained.isEmpty)
        let item = try #require(leftovers(of: collectable).first)
        #expect(item.claimCaveat == .scannedInstalledApps)
        #expect(leftoverBytes(of: collectable) >= 4096)
    }
}

// MARK: - Gate (b): cross-app containment, distinguishing integrations from shared roots

/// `CaskIndex` refuses a path two or more casks declare *identically*. It
/// cannot see a path one cask declares that is an ancestor of a different
/// app's deeper declaration, because it looks at one app at a time. The
/// assembler sees every app's declarations at once, so the check lives here.
///
/// Deliberately not plain containment: nine unrelated casks declare paths
/// strictly under `~/Library/Application Support/Google/Chrome`, all at depth
/// 2 inside Chrome's `NativeMessagingHosts` directory. Plain containment would
/// refuse Chrome's own 1.5 GB directory over integrations that should die with
/// it.
///
/// The rule is depth: a foreign declaration that is an **immediate child**
/// partitions the directory between products, so the directory is a shared
/// root and nobody may take it. A foreign declaration buried deeper is an
/// artifact planted inside one product's own internal structure, and dies
/// with that product.
@Test func aForeignImmediateChildRetainsASharedRootWhileANestedIntegrationDoesNot() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        try tree.file("Library/Application Support/Google/Chrome/Default/History", byteCount: 5000)
        try tree.file(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json",
            byteCount: 64)
        try tree.file("Library/Application Support/Microsoft/EdgeUpdater/log", byteCount: 100)
        try tree.file("Library/Application Support/Microsoft/Bing Wallpaper/cache", byteCount: 7000)

        let chromeURL = try makeAppBundle(
            tree, at: "Applications/Google Chrome.app",
            bundleID: "com.google.Chrome", displayName: "Google Chrome")
        let edgeURL = try makeAppBundle(
            tree, at: "Applications/Microsoft Edge.app",
            bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge")

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "google-chrome",
            "artifacts": [
              { "app": ["Google Chrome.app"] },
              { "zap": [{ "trash": ["\(support.path)/Google/Chrome"] }] }
            ]
          },
          {
            "token": "1password",
            "artifacts": [
              { "app": ["1Password.app"] },
              { "zap": [{ "trash": [
                "\(support.path)/Google/Chrome/NativeMessagingHosts/com.1password.1password.json"
              ] }] }
            ]
          },
          {
            "token": "microsoft-edge",
            "artifacts": [
              { "app": ["Microsoft Edge.app"] },
              { "zap": [{ "trash": ["\(support.path)/Microsoft"] }] }
            ]
          },
          {
            "token": "bing-wallpaper",
            "artifacts": [
              { "zap": [{ "trash": ["\(support.path)/Microsoft/Bing Wallpaper"] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let index = try #require(CaskIndex.load(from: caskURL))
        let apps = installedApps(scanning: [root.appendingPathComponent("Applications")])

        let chrome = FootprintAssembler.assemble(
            identity: BundleIdentity(
                bundleID: "com.google.Chrome", displayName: "Google Chrome",
                bundleURL: chromeURL, isPresent: true),
            installedApps: apps, environment: env, claimants: emptyClaimants(env),
            caskIndex: index, caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let chromeDir = Candidate.normalizedPathKey(for: support.appendingPathComponent("Google/Chrome"))
        #expect(chrome.items.contains { Candidate.normalizedPathKey(for: $0.path) == chromeDir })
        #expect(chrome.retained.isEmpty)
        #expect(chrome.reclaimableBytes >= 5000)

        let edge = FootprintAssembler.assemble(
            identity: BundleIdentity(
                bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge",
                bundleURL: edgeURL, isPresent: true),
            installedApps: apps, environment: env, claimants: emptyClaimants(env),
            caskIndex: index, caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let microsoftDir = Candidate.normalizedPathKey(for: support.appendingPathComponent("Microsoft"))
        #expect(!edge.items.contains { Candidate.normalizedPathKey(for: $0.path) == microsoftDir })
        let retained = try #require(edge.retained.first { Candidate.normalizedPathKey(for: $0.path) == microsoftDir })
        // `bing-wallpaper` has no `app` artifact at all — a real shape, and
        // the reason the gate reads raw cask declarations rather than the
        // zap paths of installed apps. With no app name to give, the cask's
        // own token is what names the retainer.
        #expect(retained.retainedFor.contains("bing-wallpaper"))
        #expect(leftoverBytes(of: edge) == 0)
    }
}

// MARK: - Arithmetic: nothing is counted twice, nothing vanishes

/// `SizeCalculator` measures a directory recursively, so an emitted ancestor
/// and an emitted descendant would each contribute the descendant's bytes.
/// A receipt is the realistic trigger: a BOM enumerates every entry it
/// installed, so one pkg installing into `Application Support/Foo` yields
/// `Foo`, `Foo/data`, `Foo/sub` and `Foo/sub/x` as four paths whose sizes
/// all sum into one headline figure.
///
/// Every other judgment in the assembler errs toward retaining, which
/// understates. This one overstates, promising space that does not exist —
/// the one direction this product's positioning cannot absorb.
@Test func nestedReceiptPathsAreCountedOnceNotOncePerLevel() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let foo = try tree.directory("Library/Application Support/Foo")
        try tree.file("Library/Application Support/Foo/data", byteCount: 4096)
        try tree.file("Library/Application Support/Foo/sub/x", byteCount: 4096)

        let env = ScanEnvironment(libraryURL: library)
        let receipt = Receipt(packageID: "com.example.nested", installPrefix: "/", bomURL: nil)
        let identity = BundleIdentity(
            bundleID: "com.example.nested", displayName: "Nested", bundleURL: nil, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in
                ["Foo", "Foo/data", "Foo/sub", "Foo/sub/x"].map {
                    Candidate.normalizedPathKey(
                        for: library.appendingPathComponent("Application Support/\($0)"))
                }
            })

        // One row, the outermost, and the collapse keeps its evidence.
        #expect(footprint.items.count == 1)
        let item = try #require(footprint.items.first)
        #expect(Candidate.normalizedPathKey(for: item.path) == Candidate.normalizedPathKey(for: foo))
        #expect(item.sources.contains(.receipt(packageID: "com.example.nested")))

        // The figure equals one recursive measurement of the outermost path.
        // Asserted against `SizeCalculator` directly rather than a literal, so
        // this pins "counted once" rather than a filesystem's block rounding.
        let once = try #require(SizeCalculator.measure(at: foo).measurement?.bytes)
        #expect(footprint.reclaimableBytes == once)
        #expect(once >= 8192)
    }
}

/// A path inside an allowlisted root that `PathGuard` refuses anyway — a
/// symlink, a root-owned entry — must be disclosed, not dropped. Dropping it
/// leaves the footprint quietly short by its size, and undisclosed
/// understatement is still dishonesty about the number.
@Test func aPathTheGuardRefusesInsideTheAllowlistIsDisclosedNotDropped() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let real = try tree.file("elsewhere/real.plist", byteCount: 512)
        try tree.directory("Library/Preferences")
        let link = try tree.symlink("Library/Preferences/com.example.linked.plist", to: real)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.linked", displayName: "Linked", bundleURL: nil, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let key = Candidate.normalizedPathKey(for: link)
        #expect(footprint.items.isEmpty)
        #expect(footprint.retained.isEmpty)
        #expect(footprint.refusedByPathGuard.map(\.path) == [key])
        #expect(footprint.refusedByPathGuard.first?.source == .shelf("Preferences"))
        // Disclosure is not an offer: the refused path is still not deletable
        // by any route, and contributes no bytes.
        #expect(footprint.reclaimableBytes == 0)
    }
}

// MARK: - The allowlist must hold at the resolved path, not only the string

/// The escape a lexical allowlist cannot see, and the reason the assertion
/// is made twice.
///
/// `~/Library/Application Support/Foo` is a symlink to `~/Dropbox/Foo`. The
/// symlink itself is refused and disclosed. But `Foo/bar` is not a symlink,
/// breaks no other rule, and sits three levels below the scan root, so the
/// guard allows it — while its unresolved key still begins with
/// `~/Library/Application Support/`, so the lexical funnel admits it. It would
/// be sized through the symlink and offered for deletion inside `~/Dropbox`,
/// and nothing downstream re-asserts the allowlist.
///
/// An invariant asserted on a string that the next stage resolves out from
/// under is not an invariant.
@Test func aDescendantOfASymlinkedAncestorIsDisclosedNotOfferedOutsideTheRoots() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let outside = try tree.directory("Dropbox/Foo")
        try tree.file("Dropbox/Foo/bar/blob", byteCount: 4096)
        try tree.directory("Library/Application Support")
        let link = try tree.symlink("Library/Application Support/Foo", to: outside)

        let env = ScanEnvironment(libraryURL: library)
        let receipt = Receipt(packageID: "com.example.escape", installPrefix: "/", bomURL: nil)
        let identity = BundleIdentity(
            bundleID: "com.example.escape", displayName: "Escape", bundleURL: nil, isPresent: true)

        let ancestorKey = Candidate.normalizedPathKey(for: link)
        let descendantKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Foo/bar"))

        // The hole, stated as a fact about `PathGuard` rather than as a
        // claim about it: with the context this engine builds, the guard
        // says yes to the escaping descendant. If this ever stops holding,
        // this test is no longer testing what it says it is.
        #expect(
            PathGuard.evaluate(
                URL(fileURLWithPath: descendantKey), removability: .removable,
                in: PathGuard.Context(scanRoot: root, declaredPaths: [])) == .allowed)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in [ancestorKey, descendantKey] })

        // Not offered, and not counted — by any route.
        #expect(footprint.items.isEmpty)
        #expect(footprint.retained.isEmpty)
        #expect(footprint.reclaimableBytes == 0)

        // Each refusal disclosed under the reason that produced it: the
        // symlink itself is a guard refusal, its descendant is outside the
        // allowlisted roots once resolved.
        #expect(footprint.refusedByPathGuard.map(\.path) == [ancestorKey])
        #expect(footprint.disclosedOutsideAllowlist.map(\.path) == [descendantKey])
        #expect(
            footprint.disclosedOutsideAllowlist.first?.source
                == .receipt(packageID: "com.example.escape"))
    }
}

/// The same escape with no admitted ancestor at all, which is the form that
/// predates the guard-before-collapse ordering: one path, under a symlinked
/// directory nothing else named, admitted lexically and allowed by the
/// guard. Nothing about the ancestor being present or absent changes where
/// the path resolves to, so the check cannot live anywhere that depends on
/// seeing the ancestor as a row.
@Test func aSingletonPathUnderASymlinkedAncestorIsAlsoStoppedAtTheResolvedAllowlist() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let outside = try tree.directory("Dropbox/Solo")
        try tree.file("Dropbox/Solo/data/blob", byteCount: 4096)
        try tree.directory("Library/Application Support")
        try tree.symlink("Library/Application Support/Solo", to: outside)

        let env = ScanEnvironment(libraryURL: library)
        let receipt = Receipt(packageID: "com.example.solo", installPrefix: "/", bomURL: nil)
        let identity = BundleIdentity(
            bundleID: "com.example.solo", displayName: "Solo", bundleURL: nil, isPresent: true)

        let descendantKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Solo/data"))

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in [descendantKey] })

        #expect(footprint.items.isEmpty)
        #expect(footprint.retained.isEmpty)
        #expect(footprint.reclaimableBytes == 0)
        // The ancestor was never a row, so there is no guard refusal to
        // disclose — only the resolved allowlist stands between this path
        // and a deletion offer inside `~/Dropbox`.
        #expect(footprint.refusedByPathGuard.isEmpty)
        #expect(footprint.disclosedOutsideAllowlist.map(\.path) == [descendantKey])
    }
}

/// The collapse that stops nested paths counting twice must not throw away
/// the reason a folded path was being retained.
///
/// The realistic shape: a BOM names both `Fabric` and a directory inside it,
/// while a different product's cask declares a bundle-id-named directory
/// immediately inside the latter, retaining it. Folding it into `Fabric`
/// carrying only its sources leaves `Fabric` judged on its own terms — no
/// immediate foreign child of its own — so it lands in `items`, sized over the
/// shared subtree and fully offered.
///
/// Recomputing after the collapse cannot save it: the foreign declaration is
/// not an immediate child of the ancestor, so a later pass sees nothing.
@Test func aSharedSubtreeFoldedIntoAnAncestorKeepsItsRetention() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let fabric = try tree.directory("Library/Application Support/Fabric")
        let shared = try tree.directory("Library/Application Support/Fabric/io.fabric.sdk.mac.data")
        try tree.file("Library/Application Support/Fabric/own.db", byteCount: 2048)
        try tree.file(
            "Library/Application Support/Fabric/io.fabric.sdk.mac.data/com.clipy-app.Clipy/blob",
            byteCount: 4096)

        let duetURL = try makeAppBundle(
            tree, at: "Applications/Duet.app", bundleID: "com.example.duet", displayName: "Duet")

        // Only the *foreign* product ships a cask here. Gate (b) must see it
        // through the raw declaration index, not through any installed-app
        // query anchored on Duet.
        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "clipy",
            "artifacts": [
              { "app": ["Clipy.app"] },
              { "zap": [{ "trash": [
                "\(support.path)/Fabric/io.fabric.sdk.mac.data/com.clipy-app.Clipy"
              ] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let receipt = Receipt(packageID: "com.example.duet", installPrefix: "/", bomURL: nil)
        let identity = BundleIdentity(
            bundleID: "com.example.duet", displayName: "Duet", bundleURL: duetURL, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskIndex: CaskIndex.load(from: caskURL),
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in
                [Candidate.normalizedPathKey(for: fabric), Candidate.normalizedPathKey(for: shared)]
            })

        // Still collapsed to one row — the arithmetic fix is intact.
        #expect(leftovers(of: footprint).count + footprint.retained.count == 1)

        // And that one row is retained, not offered.
        #expect(leftovers(of: footprint).isEmpty)
        let merged = try #require(footprint.retained.first)
        #expect(Candidate.normalizedPathKey(for: merged.path) == Candidate.normalizedPathKey(for: fabric))
        #expect(merged.retainedFor.contains("Clipy.app"))
        #expect(!merged.isDeletable)
    }
}

/// The same inheritance rule at **three** levels, which is the only depth
/// that can tell the implemented rule apart from the one a maintainer would
/// plausibly simplify it to.
///
/// The two-level version pins inheritance but not *which* ancestor inherits,
/// because there the nearest and outermost ancestor are the same node. Here a
/// BOM names three nested levels and a foreign cask retains only the deepest.
///
/// Fold into the nearest ancestor rather than the outermost and, in
/// parent-first order, the middle level inherits the retainer and is then
/// discarded into the top level — which was already processed, while the middle
/// still carried nothing. The top level survives with no retainer and is
/// offered for deletion over the shared subtree.
@Test func aSharedSubtreeFoldsIntoTheOutermostAncestorNotTheNearest() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let aperture = try tree.directory("Library/Application Support/Aperture")
        let extensions = try tree.directory("Library/Application Support/Aperture/Extensions")
        let shared = try tree.directory("Library/Application Support/Aperture/Extensions/Shared")
        try tree.file("Library/Application Support/Aperture/own.db", byteCount: 2048)
        try tree.file(
            "Library/Application Support/Aperture/Extensions/Shared/com.clipy-app.Clipy/blob",
            byteCount: 4096)

        let apertureURL = try makeAppBundle(
            tree, at: "Applications/Aperture.app", bundleID: "com.example.aperture",
            displayName: "Aperture")

        // The declaration is an immediate child of the *deepest* path only.
        // Neither `Aperture` nor `Aperture/Extensions` has a foreign
        // immediate child of its own, so nothing but inheritance can retain
        // the row that survives.
        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "clipy",
            "artifacts": [
              { "app": ["Clipy.app"] },
              { "zap": [{ "trash": [
                "\(support.path)/Aperture/Extensions/Shared/com.clipy-app.Clipy"
              ] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let receipt = Receipt(packageID: "com.example.aperture", installPrefix: "/", bomURL: nil)
        let identity = BundleIdentity(
            bundleID: "com.example.aperture", displayName: "Aperture", bundleURL: apertureURL,
            isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskIndex: CaskIndex.load(from: caskURL),
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in
                [aperture, extensions, shared].map { Candidate.normalizedPathKey(for: $0) }
            })

        // Three levels collapse to one row, and it is the outermost.
        #expect(leftovers(of: footprint).count + footprint.retained.count == 1)

        // The retainer travelled two levels up, not one: the surviving row
        // is retained rather than offered, and its bytes are not promised.
        #expect(leftovers(of: footprint).map(\.path) == [])
        #expect(leftoverBytes(of: footprint) == 0)

        let merged = try #require(footprint.retained.first)
        #expect(
            Candidate.normalizedPathKey(for: merged.path)
                == Candidate.normalizedPathKey(for: aperture))
        #expect(merged.retainedFor.contains("Clipy.app"))
        #expect(!merged.isDeletable)
    }
}

/// Found by driving the shipped app . Brave's detail pane
/// listed three paths under "Refused by DevDriveCacheClean's Safety Check",
/// beneath the sentence "Brave owns more than what is offered above." None
/// of the three existed. They came from the brave-browser cask's
/// `zap trash:` stanza — declared paths, not enumerated ones, so nothing
/// upstream had checked whether this machine had them — and `PathGuard`
/// refused each as "owned by root", `isRootOwned` being unable to read the
/// attributes of a path that is not there.
///
/// Disclosing them claims the app owns bytes it does not, which is an
/// over-report in the one dimension this product's positioning turns on.
/// The refusal stays; only the disclosure is dropped, and only for absence.
@Test func aPathThatDoesNotExistIsNotDisclosedAsRefusedTerritory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.directory("Library/Application Support")
        let real = try tree.file("Library/Application Support/Ghost/kept.data", byteCount: 2_048)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.ghost", displayName: "Ghost", bundleURL: nil, isPresent: false)
        let receipt = Receipt(packageID: "com.example.ghost", installPrefix: "/", bomURL: nil)

        // The shape of a cask zap stanza on a machine that never had the
        // app's caches: one path present, two named but absent — and the
        // second absent one two levels deep, so its immediate parent cannot
        // answer either. That is Brave's exact case.
        let realKey = Candidate.normalizedPathKey(for: real.deletingLastPathComponent())
        let phantom = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/NeverExisted"))
        let deepPhantom = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Nowhere/AlsoGone"))

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in [realKey, phantom, deepPhantom] })

        // Stated as a fact about the guard, not assumed of it: both phantoms
        // are still refused, under the reason that says nothing is withheld.
        for absent in [phantom, deepPhantom] {
            #expect(
                PathGuard.evaluate(
                    URL(fileURLWithPath: absent), removability: .removable,
                    in: PathGuard.Context(
                        scanRoot: library.deletingLastPathComponent(), declaredPaths: []))
                    == .refused(reason: PathGuard.doesNotExistReason))
        }

        #expect(footprint.items.map(\.id) == [realKey])
        #expect(footprint.refusedByPathGuard.isEmpty)
        #expect(footprint.disclosedOutsideAllowlist.isEmpty)
    }
}

/// The other half of the rule, and the reason the drop is keyed on one
/// specific reason rather than on refusal in general: a real path refused
/// for a real reason must still be disclosed. Without this, dropping every
/// refusal would leave the test above passing.
@Test func aRealRefusedPathIsStillDisclosedAlongsideADroppedPhantom() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let outside = try tree.file("elsewhere/real.plist", byteCount: 512)
        try tree.directory("Library/Preferences")
        let link = try tree.symlink("Library/Preferences/com.example.mixed.plist", to: outside)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.mixed", displayName: "Mixed", bundleURL: nil, isPresent: true)
        let receipt = Receipt(packageID: "com.example.mixed", installPrefix: "/", bomURL: nil)
        let phantom = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Preferences/com.example.mixed.absent.plist"))

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), receipts: [receipt],
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in [phantom] })

        #expect(footprint.refusedByPathGuard.map(\.path) == [Candidate.normalizedPathKey(for: link)])
    }
}

// MARK: - The application bundle itself
//
// The bundle does not go through the allowlist funnel, because the allowlist
// describes `~/Library` shelves and the bundle lives in /Applications. It
// goes through `PathGuard` with its own path declared, which bypasses only
// the containment and depth rules — every destructive check still runs, so a
// symlink, a root-owned bundle, a volume root or a protected directory is
// refused exactly as before.

@Test func anInstalledAppOffersItsOwnBundle() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let bundle = try makeAppBundle(
            tree, at: "Applications/Example.app", bundleID: "com.example.app", displayName: "Example")
        try tree.file("Applications/Example.app/Contents/MacOS/Example", byteCount: 40_960)

        let env = ScanEnvironment(libraryURL: library)
        let apps = installedApps(scanning: [root.appendingPathComponent("Applications")])
        let installed = try #require(apps.byID["com.example.app"])
        let identity = BundleIdentity(
            bundleID: installed.bundleID, displayName: installed.displayName,
            bundleURL: installed.bundleURL, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: apps, environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let bundleKey = Candidate.normalizedPathKey(for: bundle)
        let offered = try #require(footprint.items.first { $0.id == bundleKey })
        #expect(offered.sources.contains(.appBundle))
        #expect(offered.sizeBytes > 0, "the bundle is offered but never measured")
        #expect(footprint.reclaimableBytes >= offered.sizeBytes)
    }
}

/// An identity with no bundle on disk — the leftovers-only case that is most
/// of what this view is for — has nothing to offer beyond its leftovers.
@Test func anIdentityThatIsGoneOffersNoBundle() throws {
    try withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.gone", displayName: "Gone", bundleURL: nil, isPresent: false)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        #expect(!footprint.items.contains { $0.sources.contains(.appBundle) })
    }
}

/// The guard still guards. Declaring the bundle's path bypasses containment
/// and depth and nothing else, so a bundle that is really a symlink is
/// refused — and disclosed rather than dropped, because a bundle this engine
/// will not remove is exactly the kind of thing a user needs told.
@Test func aBundleTheGuardRefusesIsDisclosedRatherThanOffered() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let real = try makeAppBundle(
            tree, at: "Elsewhere/Real.app", bundleID: "com.example.linked", displayName: "Linked")
        try tree.directory("Applications")
        let link = try tree.symlink("Applications/Linked.app", to: real)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.linked", displayName: "Linked", bundleURL: link, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        #expect(!footprint.items.contains { $0.sources.contains(.appBundle) })
        #expect(footprint.refusedByPathGuard.map(\.path)
            == [Candidate.normalizedPathKey(for: link)])
    }
}

/// A running app refuses its whole footprint, bundle included. Deleting a
/// bundle out from under a live process is the one case where being wrong is
/// not recoverable by re-running the sweep.
@Test func aRunningAppOffersNoBundleEither() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        _ = try makeAppBundle(
            tree, at: "Applications/Live.app", bundleID: "com.example.live", displayName: "Live")

        let env = ScanEnvironment(libraryURL: library)
        let apps = installedApps(scanning: [root.appendingPathComponent("Applications")])
        let installed = try #require(apps.byID["com.example.live"])
        let identity = BundleIdentity(
            bundleID: installed.bundleID, displayName: installed.displayName,
            bundleURL: installed.bundleURL, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: apps, environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in true })

        #expect(footprint.refusal == .appIsRunning)
        #expect(footprint.items.isEmpty)
    }
}

/// A pkg-installed app's bundle is root-owned, which the guard refuses. That
/// refusal is clearable — Finder performs the move after authenticating — so
/// the assembler must offer the bundle marked as needing authentication rather
/// than disclose it as territory DDCC will not touch.
///
/// The bundle is a real root-owned directory: creating one needs privileges the
/// test process does not have, and ownership is the entire point. The identity
/// deliberately carries a non-Apple bundle id, since Apple's namespace is
/// refused before any of this is reached.
@Test func aRootOwnedBundleIsOfferedAsNeedingAuthenticationNotDisclosedAsRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("Library")
        let env = ScanEnvironment(libraryURL: library)
        let rootOwned = URL(fileURLWithPath: "/System/Applications/Calculator.app")

        let identity = BundleIdentity(
            bundleID: "com.example.pkgapp", displayName: "PkgApp",
            bundleURL: rootOwned, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] },
            isRunning: { _ in false }, measure: { _ in 1_000 })

        let bundle = try #require(footprint.items.first { $0.sources.contains(.appBundle) })
        #expect(bundle.requiresAuthentication)
        #expect(bundle.isDeletable)
        #expect(footprint.disclosedOutsideAllowlist.contains { $0.source == .appBundle } == false)
    }
}

/// The counterpart: a bundle this user owns needs no authentication, so the
/// flag must not be set for the ordinary case. Without this, marking every
/// bundle would pass the test above and prompt the user for a password on
/// every single uninstall.
@Test func aUserOwnedBundleIsOfferedWithoutRequiringAuthentication() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("Library")
        let env = ScanEnvironment(libraryURL: library)
        let bundleURL = try makeAppBundle(
            tree, at: "Applications/Owned.app", bundleID: "com.example.owned",
            displayName: "Owned")

        let identity = BundleIdentity(
            bundleID: "com.example.owned", displayName: "Owned",
            bundleURL: bundleURL, isPresent: true)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] },
            isRunning: { _ in false }, measure: { _ in 1_000 })

        let bundle = try #require(footprint.items.first { $0.sources.contains(.appBundle) })
        #expect(bundle.requiresAuthentication == false)
    }
}

/// A receipt-anchored identity carries no `app` artifact to match, so
/// without the token-anchored branch here its footprint is always empty —
/// correct, tested logic that no caller reaches. This asserts the branch is
/// wired, at the layer that would silently return nothing if it were not.
@Test func aReceiptAnchoredIdentityReceivesItsCasksDeclaredPaths() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try tree.file("Library/Application Support/AutoUpdate/marker", byteCount: 2)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "auto-update", "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.autoupdate" } ] },
              { "zap": [ { "trash": "\(library.path)/Application Support/AutoUpdate" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        // The shape `RecoveredIdentities` actually mints for this arm: no
        // bundle, and present. The token is the only anchor available, which is
        // exactly what this test is about.
        let identity = BundleIdentity(
            bundleID: "auto-update", displayName: "auto-update",
            bundleURL: nil, isPresent: true, namespace: .caskReceipt)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskIndex: caskIndex,
            caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let declared = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/AutoUpdate"))
        #expect(footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == declared })
    }
}

/// A cask with no `app` artifact is looked up by its own token, and the
/// cross-app containment gate has to be asked by that same anchor. Asked by
/// app bundle name instead, it excludes declarations carrying an app name
/// the row does not have — which excludes nothing — so the row's own deeper
/// declaration comes back as a *stranger's* claim on its own ancestor. The
/// path is then retained, and the product named as keeping it is the row
/// itself.
///
/// The shelf supplies the ancestor here, so the cask's own Rule 2 has no
/// chance to remove it first and the gate really is asked about a directory
/// above the cask's own declaration.
@Test func aTokenAnchoredCaskIsNotAStrangerToItsOwnAncestor() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        try tree.file("Library/Application Support/vendor-tool/Cache/blob", byteCount: 4000)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "vendor-tool",
            "artifacts": [
              { "uninstall": [{ "pkgutil": "com\\\\.example\\\\.vendortool" }] },
              { "zap": [{ "trash": ["\(support.path)/vendor-tool/Cache"] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let index = try #require(CaskIndex.load(from: caskURL))

        let footprint = FootprintAssembler.assemble(
            identity: BundleIdentity(
                bundleID: "vendor-tool", displayName: "vendor-tool",
                bundleURL: nil, isPresent: true, namespace: .caskReceipt),
            installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskIndex: index, caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let vendorDir = Candidate.normalizedPathKey(for: support.appendingPathComponent("vendor-tool"))
        #expect(!footprint.retained.contains { Candidate.normalizedPathKey(for: $0.path) == vendorDir })
        #expect(footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == vendorDir })
    }
}

/// **No item is ever offered at a path that is not there.** The bundle is the
/// one item no evidence source produced and no allowlist vetted, so it is the
/// one that can be a phantom: `PathGuard` cannot prove a path absent when
/// every ancestor is missing too (`isAbsent`'s walk stops at `/` and returns
/// `false`), so the verdict falls through to `isRootOwned`, which refuses on an
/// unreadable path, which `requiresElevation` reads as the one clearable
/// refusal. An identity carrying a `bundleURL` nothing sits at would therefore
/// be offered a deletion at a guaranteed-absent path, marked as needing an
/// admin password.
///
/// Asserted for a **present** identity, because presence is not the property
/// that makes a bundle real — a real bundle at `bundleURL` is.
@Test func noBundleIsOfferedAtAPathThatDoesNotExist() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("Library")
        let env = ScanEnvironment(libraryURL: library)
        let phantom = URL(fileURLWithPath: "/nonexistent/recovered-from-cask/vendor-tool")

        let identity = BundleIdentity(
            bundleID: "vendor-tool", displayName: "vendor-tool",
            bundleURL: phantom, isPresent: true, namespace: .caskReceipt)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskPresence: nil,
            applicationGroups: { _ in [] },
            isRunning: { _ in false }, measure: { _ in 1_000 })

        #expect(!footprint.items.contains { $0.sources.contains(.appBundle) })
        // The general property, not only this one source: nothing offered may
        // name a path that is not on disk.
        #expect(!footprint.items.contains {
            !FileManager.default.fileExists(atPath: $0.path.path(percentEncoded: false))
        })
    }
}

/// The `declaresApp` half of `caskAnchor`'s condition, pinned.
///
/// Both halves are load-bearing, and this one is not about a footprint
/// coming back short. A cask-recovered identity that DOES name an app is
/// reachable by either anchor, so dropping the check costs nothing visible
/// on a cask that stands alone. It costs everything on a cask with sibling
/// variants: `vendor-suite` and `vendor-suite@beta` both declare
/// `VendorSuite.app`, so the app anchor puts both in one group and Rule 2
/// sees the beta's deeper path sitting under the bare `VendorVault` the
/// base cask declares — and refuses the bare ancestor. The token anchor
/// groups by token alone, which **shrinks the Rule 2 own-path union** to
/// the base cask's single bare path, leaving nothing beneath it to prefer.
/// Rule 3 does not catch it either: it refuses only a path another cask
/// declares *identically*, and the beta declares a descendant, not the same
/// string. Gate (b) does not catch it either, because that declaration is
/// not an immediate child.
///
/// So the bare vendor directory — which holds the beta's live state — is
/// offered for deletion. The error direction is RELEASE, not under-report,
/// which is the direction this engine cannot absorb.
@Test func anAppNamingCaskRecoveredIdentityStaysOnTheAppAnchor() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        try tree.file("Library/Application Support/VendorVault/Beta/State/blob", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          {
            "token": "vendor-suite",
            "artifacts": [
              { "app": ["VendorSuite.app"] },
              { "zap": [{ "trash": ["\(support.path)/VendorVault"] }] }
            ]
          },
          {
            "token": "vendor-suite@beta",
            "artifacts": [
              { "app": ["VendorSuite.app"] },
              { "zap": [{ "trash": ["\(support.path)/VendorVault/Beta/State"] }] }
            ]
          }
        ]
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let index = try #require(CaskIndex.load(from: caskURL))

        // Exactly the shape `RecoveredIdentities` mints for a cask that does
        // declare an `app`: the token in `bundleID`, `.caskToken`, and a
        // synthetic bundle location that exists nowhere.
        let identity = BundleIdentity(
            bundleID: "vendor-suite", displayName: "VendorSuite",
            bundleURL: URL(fileURLWithPath: "/nonexistent/recovered-from-cask/VendorSuite.app"),
            isPresent: false, namespace: .caskToken)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskIndex: index, caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let vault = Candidate.normalizedPathKey(for: support.appendingPathComponent("VendorVault"))
        let betaState = Candidate.normalizedPathKey(
            for: support.appendingPathComponent("VendorVault/Beta/State"))

        // The shared vendor directory is never offered, and never merely
        // retained either — Rule 2 removed it before any gate saw it.
        #expect(!footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == vault })
        #expect(!footprint.retained.contains { Candidate.normalizedPathKey(for: $0.path) == vault })

        // Positive control: the specific declaration is still reached, so
        // the absence above is Rule 2 and not an empty query.
        #expect(footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == betaState })
    }
}

/// The same condition read the other way. `declaresApp` answers `nil` when the
/// index could not read a token's `app` artifacts at all — a `:target` naming
/// an explicit path, or an entry whose shape this reader does not know — and
/// "could not read" is not "declares none". Taking the token anchor on it
/// would shrink the Rule 2 own-path union exactly as the test above describes,
/// and offer the bare vendor directory holding the beta's live state.
///
/// So a withheld answer keeps the app anchor, which is the retaining
/// direction: the base cask contributes no name, so its bare path is simply
/// never reached, and only the sibling's own deeper declaration is offered.
@Test func aCaskWhoseAppArtifactCouldNotBeReadStaysOnTheAppAnchor() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        try tree.file("Library/Application Support/VendorVault/Beta/State/blob", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        { "casks": {
            "vendor-suite": { "raw_artifacts": [
              [":app", ["Install VendorSuite.app/Contents/Resources/VendorSuite.app"],
                       { ":target": "~/Library/Application Support/VendorVault/VendorSuite.app" }],
              [":zap", { ":trash": ["\(support.path)/VendorVault"] }] ] },
            "vendor-suite@beta": { "raw_artifacts": [
              [":app", ["VendorSuite.app"]],
              [":zap", { ":trash": ["\(support.path)/VendorVault/Beta/State"] }] ] } } }
        """, to: caskURL)

        let env = ScanEnvironment(libraryURL: library)
        let index = try #require(CaskIndex.load(from: caskURL))

        let identity = BundleIdentity(
            bundleID: "vendor-suite", displayName: "VendorSuite",
            bundleURL: URL(fileURLWithPath: "/nonexistent/recovered-from-cask/VendorSuite.app"),
            isPresent: false, namespace: .caskToken)

        let footprint = FootprintAssembler.assemble(
            identity: identity, installedApps: installedApps(scanning: []), environment: env,
            claimants: emptyClaimants(env), caskIndex: index, caskPresence: nil,
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let vault = Candidate.normalizedPathKey(for: support.appendingPathComponent("VendorVault"))
        #expect(!footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == vault })
        #expect(!footprint.retained.contains { Candidate.normalizedPathKey(for: $0.path) == vault })

        // Positive control, the same one the test above carries: the app
        // anchor really did run and really did reach a declaration, so the two
        // absences are the withheld vault and not a fixture that assembled
        // nothing.
        let betaState = Candidate.normalizedPathKey(
            for: support.appendingPathComponent("VendorVault/Beta/State"))
        #expect(footprint.items.contains { Candidate.normalizedPathKey(for: $0.path) == betaState })
    }
}
