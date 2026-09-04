import Testing
import Foundation
@testable import DDCCCore

private var allPatterns: [(CleanCategory, ScanProfile.Pattern)] {
    ScanProfile.all.flatMap { profile in profile.patterns.map { (profile.category, $0) } }
}

private func pattern(matchingPath needle: String) -> ScanProfile.Pattern? {
    allPatterns.first { _, pattern in
        if case .absolutePath(let path) = pattern.kind { return path == needle }
        return false
    }?.1
}

private func category(ofPathPattern needle: String) -> CleanCategory? {
    allPatterns.first { _, pattern in
        if case .absolutePath(let path) = pattern.kind { return path == needle }
        return false
    }?.0
}

private func pattern(matchingDirectoryNamed needle: String) -> ScanProfile.Pattern? {
    allPatterns.first { _, pattern in
        if case .directoryName(let name, _) = pattern.kind { return name == needle }
        return false
    }?.1
}

/// A stable, human-readable identifier for a pattern's location, independent
/// of which `Kind` case reaches it. Used to build a table-derived set of
/// destructive entries rather than a hand-picked subset, so that adding,
/// removing, or re-tiering a destructive entry changes this set and the
/// comparison against the explicit expected set below fails until updated
/// deliberately.
private func destructiveIdentifier(for kind: ScanProfile.Pattern.Kind) -> String? {
    switch kind {
    case .absolutePath(let path):
        return path
    case .subdirectories(let parentPath, _):
        return parentPath
    case .engineVersions(let parentPath, _, _):
        return parentPath
    case .toolchainVersions(let parentPath, _, _, _):
        return parentPath
    case .childSubpath(let parentPath, let subpath, _):
        return "\(parentPath)::\(subpath)"
    case .directoryName(let name, _):
        return name
    }
}

/// Exhaustive, not a sample. Every entry DDCC shows but cannot delete has to
/// be listed here, so adding one is a deliberate act: an informational entry
/// contributes to the headline total while being unreclaimable, and that gap
/// is exactly what the tool exists not to hide.
@Test func onlyRootOwnedSystemPathsRequirePrivileges() {
    let locked = allPatterns.compactMap { _, pattern -> String? in
        guard pattern.removability == .requiresPrivileges else { return nil }
        guard case .absolutePath(let path) = pattern.kind else { return nil }
        return path
    }
    #expect(Set(locked) == [
        "/Library/Caches",
        "/System/Library/Caches",
        "/Library/Developer/CoreSimulator/Images",
    ])
}

@Test func noPatternIsBothLockedAndUnderHome() {
    for (_, pattern) in allPatterns where pattern.removability == .requiresPrivileges {
        guard case .absolutePath(let path) = pattern.kind else { continue }
        #expect(path.hasPrefix("~") == false)
    }
}

@Test func perProjectArtifactsAreSafe() {
    for name in ["node_modules", "__pycache__", ".venv", ".next", ".tox", ".mypy_cache"] {
        #expect(pattern(matchingDirectoryNamed: name)?.tier == .safe, "\(name)")
    }
}

@Test func globalCachesAreCostly() {
    for path in [
        "~/.cargo/registry", "~/.npm/_cacache", "~/.pnpm-store",
        "~/.gradle/caches", "~/go/pkg/mod/cache", "~/Library/Caches/Homebrew",
        "~/Library/Developer/Xcode/iOS DeviceSupport",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .costly, "\(path)")
    }
}

@Test func irreplaceablePathsAreDestructive() {
    for path in [
        "~/Library/Developer/Xcode/Archives",
        "~/Library/Developer/CoreSimulator/Devices",
        "~/.vscode/extensions",
        "~/Library/Application Support/JetBrains",
        "~/Library/Safari/LocalStorage",
        "~/Library/Containers/com.docker.docker/Data",
        "~/Library/Mail Downloads",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .destructive, "\(path)")
    }
}

/// Every `.destructive` entry in the table must appear in this explicit
/// expected set. This is exhaustive, not a sample: if a destructive entry is
/// re-tiered, added, or removed without updating this list, the set
/// comparison fails. That includes
/// `~/Library/Application Support/MobileSync/Backup`, which is potentially
/// the only copy of a device's data and is reached via a `.subdirectories`
/// pattern rather than `.absolutePath`.
@Test func everyDestructiveEntryIsPinnedByTheTable() {
    let expected: Set<String> = [
        "~/Library/Developer/Xcode/Archives",
        // The same argument as CoreSimulator/Devices, for the other platform.
        // An AVD holds the apps installed inside the emulator and whatever
        // state they wrote; recreating the device gives back a blank one.
        "~/.android/avd",
        "~/Library/Developer/CoreSimulator/Devices",
        "~/Library/Containers/com.docker.docker/Data",
        "~/.vscode/extensions",
        "~/Library/Application Support/JetBrains",
        "~/Library/Safari/LocalStorage",
        "~/Library/Safari/Databases",
        "~/Library/Safari/ServiceWorkers",
        "~/Library/Application Support/Google/Chrome/Default/Service Worker",
        "~/Library/Application Support/MobileSync/Backup",
        "~/Library/Mail Downloads",
        "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
    ]

    let actual = Set(allPatterns.compactMap { _, pattern -> String? in
        guard pattern.tier == .destructive else { return nil }
        return destructiveIdentifier(for: pattern.kind)
    })

    #expect(actual == expected)
}

@Test func derivedDataIsSafeEvenThoughArchivesIsNot() {
    #expect(pattern(matchingPath: "~/Library/Developer/Xcode/DerivedData")?.tier == .safe)
    #expect(pattern(matchingPath: "~/Library/Developer/Xcode/Archives")?.tier == .destructive)
}

/// Containers hold user documents. The profile must reach the cache inside
/// each container, never enumerate the containers themselves.
@Test func containersAreReachedByChildSubpathNotEnumeration() {
    let enumeratesContainers = allPatterns.contains { _, pattern in
        if case .subdirectories(let parent, _) = pattern.kind {
            return parent.contains("Library/Containers")
        }
        return false
    }
    #expect(enumeratesContainers == false)

    let childPaths = allPatterns.compactMap { _, pattern -> (String, String)? in
        guard case .childSubpath(let parent, let subpath, _) = pattern.kind else { return nil }
        return (parent, subpath)
    }
    #expect(childPaths.contains { $0.0 == "~/Library/Containers" && $0.1 == "Data/Library/Caches" })
}

@Test func bareNpmDirectoryPatternIsRemoved() {
    #expect(pattern(matchingDirectoryNamed: ".npm") == nil)
}

@Test func gradleDirectoryPatternRequiresAMarker() throws {
    let gradle = try #require(pattern(matchingDirectoryNamed: ".gradle"))
    guard case .directoryName(_, let marker) = gradle.kind else {
        Issue.record("expected a directoryName kind")
        return
    }
    #expect(marker != nil)
}

@Test func venvUsesAChildMarker() throws {
    let venv = try #require(pattern(matchingDirectoryNamed: "venv"))
    guard case .directoryName(_, let marker) = venv.kind,
          case .child(let file) = marker else {
        Issue.record("expected venv to use a child marker")
        return
    }
    #expect(file == "pyvenv.cfg")
}

/// `declaredAbsolutePaths` pins `isDirectory: false` when standardizing so
/// that whether a declared path happens to already exist on the running
/// machine's disk cannot change its shape. Without that pin, a path that
/// exists as a real directory gets a trailing slash appended (verified by
/// reproducing the failure on a machine with a real
/// `~/Library/Developer/Xcode/DerivedData`) while a path that does not
/// exist does not — so the two assertions below (`allSatisfy` over the
/// whole set, not a single example) hold regardless of which declared
/// paths exist locally: the set always mixes some that do and some that
/// don't, and the invariant is meant to be true for both.
@Test func declaredAbsolutePathsAreExpandedAndStandardized() {
    let declared = ScanProfile.declaredAbsolutePaths
    #expect(declared.isEmpty == false)
    #expect(declared.allSatisfy { $0.hasPrefix("/") })
    #expect(declared.allSatisfy { $0.hasSuffix("/") == false })
    #expect(declared.contains { $0.hasSuffix("/DerivedData") })
}

@Test func noCategoryIsEmpty() {
    for profile in ScanProfile.all {
        #expect(profile.patterns.isEmpty == false, "\(profile.category.rawValue)")
    }
}

// MARK: - App deep clean

@Test func appDeepCleanCategoryExists() {
    #expect(CleanCategory.allCases.contains(.appDeepClean))
    #expect(ScanProfile.all.contains { $0.category == .appDeepClean })
}

@Test func appDeepCleanCostlyEntriesAreCostly() {
    for path in [
        "~/Library/Application Support/Claude/vm_bundles",
        "~/Library/Application Support/Code/WebStorage",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .costly, "\(path)")
    }
}

/// Per version, and only for versions no installed Godot uses. Measured: 4.7.2
/// was the installed editor while both template directories were 4.6.1, so the
/// whole 2.0 GB belonged to no editor.
@Test func godotExportTemplatesAreOfferedOnlyForUninstalledVersions() throws {
    let entry = ScanProfile.all
        .first { $0.category == .gameEngines }?
        .patterns
        .first { pattern in
            if case .engineVersions(let parent, _, _) = pattern.kind {
                return parent.hasSuffix("Godot/export_templates")
            }
            return false
        }
    let found = try #require(
        entry, "export_templates must be judged against the installed Godot")
    guard case .engineVersions(_, let engine, _) = found.kind else {
        Issue.record("expected an engineVersions pattern")
        return
    }
    #expect(engine == .godot)
    #expect(found.tier == .costly)
}

@Test func appDeepCleanSafeEntriesAreSafe() {
    for path in [
        "~/Library/Application Support/Code/logs",
        "~/Library/Application Support/Code/blob_storage",
        "~/Library/Application Support/Code/Crashpad",
        "~/Library/Application Support/Code/CachedProfilesData",
        "~/Library/Application Support/Claude/Code Cache",
        "~/Library/Application Support/Claude/GPUCache",
        "~/Library/Application Support/Claude/DawnWebGPUCache",
        "~/Library/Application Support/Claude/DawnGraphiteCache",
        "~/Library/Application Support/Godot/shader_cache",
        "~/.codex/cache",
        "~/.claude/cache",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .safe, "\(path)")
    }
}

// MARK: - Toolchain cache coverage

/// A machine-wide cache that refills from inputs already on disk, with no
/// network, is tier 1 — even though the usual shorthand for tier 1 is
/// "per-project, restorable from a manifest in the project". `go-build`
/// recompiles from local sources; the Xcode cache re-derives from the
/// installed toolchain. Anything that refills by DOWNLOADING stays costly no
/// matter how automatic the refill is, which is what separates these two from
/// the list in `redownloadedToolchainCachesAreCostly`.
@Test func locallyRebuildableMachineWideCachesAreSafe() {
    for path in [
        "~/Library/Caches/go-build",
        "~/Library/Caches/com.apple.dt.Xcode",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .safe, "\(path)")
    }
}

@Test func redownloadedToolchainCachesAreCostly() {
    for path in [
        "~/.m2/repository",
        "~/.bun/install/cache",
        "~/Library/Caches/deno",
        "~/.cache/uv",
        "~/Library/Developer/CoreSimulator/Profiles/Runtimes",
        "~/Library/Developer/Xcode/DocumentationCache",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .costly, "\(path)")
    }
}

/// The two `CoreSimulator` children sit two tiers apart on purpose. `Profiles/
/// Runtimes` is tens of GB of OS images that re-download and hold no user
/// data; the sibling `Devices` holds installed simulator apps and everything
/// they have written. Being neighbours must never collapse them together.
@Test func simulatorRuntimesAreCostlyEvenThoughDevicesIsDestructive() {
    let runtimes = "~/Library/Developer/CoreSimulator/Profiles/Runtimes"
    #expect(pattern(matchingPath: runtimes)?.tier == .costly)
    #expect(pattern(matchingPath: "~/Library/Developer/CoreSimulator/Devices")?.tier == .destructive)
}

/// Xcode 14 moved downloaded runtimes out of the user's home into a
/// root-owned system directory, so covering only the legacy path would
/// silently understate the total on any current machine. The modern location
/// is deletable by root alone, hence informational rather than removable.
@Test func modernSimulatorRuntimeImagesAreCoveredButLocked() throws {
    let images = try #require(pattern(matchingPath: "/Library/Developer/CoreSimulator/Images"))
    #expect(images.removability == .requiresPrivileges)
    #expect(images.tier == .costly)
    #expect(category(ofPathPattern: "/Library/Developer/CoreSimulator/Images") == .xcode)
}

/// Three of these live under `~/Library/Caches`, which the appCaches profile
/// sweeps wholesale at tier 1. Declaring them explicitly is what files them
/// under the toolchain that owns them — and, for `deno`, what raises the tier
/// the sweep would otherwise assign. So the category is the property under
/// test here, not just the tier.
@Test func toolchainCachesAreFiledUnderTheirOwnCategory() {
    let expected: [String: CleanCategory] = [
        "~/Library/Caches/go-build": .goLang,
        "~/.cache/uv": .python,
        "~/.m2/repository": .packageCaches,
        "~/.bun/install/cache": .packageCaches,
        "~/Library/Caches/deno": .packageCaches,
        "~/Library/Developer/CoreSimulator/Profiles/Runtimes": .xcode,
        "~/Library/Developer/Xcode/DocumentationCache": .xcode,
    ]
    for (path, expectedCategory) in expected {
        #expect(category(ofPathPattern: path) == expectedCategory, "\(path)")
    }
}

@Test func vsCodeExtensionCacheIsNotDuplicatedIntoAppDeepClean() {
    // Already covered by the ideData profile at tier 1. Duplicating it here
    // would produce two candidates for one path and rely on dedup to clean up.
    let inDeepClean = ScanProfile.all
        .first { $0.category == .appDeepClean }?
        .patterns
        .contains { pattern in
            if case .absolutePath(let p) = pattern.kind {
                return p.hasSuffix("CachedExtensionVSIXs")
            }
            return false
        } ?? false
    #expect(inDeepClean == false)
}

// MARK: - Unreal Engine coverage
//
// Measured on the development machine, 2026-08-29, UE 5.8 with one project and
// eight Fab store assets:
//
//   /Users/Shared/UnrealEngine/Launcher/VaultCache            21 GB
//   /Users/Shared/Epic Games/UE_5.8/Engine/DerivedDataCache  2.9 GB
//   /Users/Shared/Epic Games/UE_5.8/Engine/Intermediate      2.5 GB
//   ~/…/Epic/UnrealEngine/Common/DerivedDataCache            634 MB
//   ~/…/Epic/UnrealEngine/Common/Zen/Data                    444 MB
//   ~/…/Epic/EpicGamesLauncher/Data/ContentCache             213 MB
//   ~/…/Epic/UnrealEngine/5.8/Intermediate                   119 MB
//   ~/Documents/Unreal Projects/MyProject/Intermediate       122 MB
//
// The engine install itself (43 GB) is deliberately absent: it is the product,
// not a cache, and removing it is an uninstall rather than a clean.

/// The vault cache is the launcher's copy of every store asset already
/// downloaded, kept beside — not instead of — the copy imported into a
/// project's Content. It is the largest single reclaimable figure this
/// project has measured, and it is enumerated per asset so one 18 GB pack can
/// go without taking the other seven with it.
@Test func unrealVaultCacheIsEnumeratedPerAssetAtCostly() throws {
    let entry = ScanProfile.all
        .first { $0.category == .gameEngines }?
        .patterns
        .first { pattern in
            if case .subdirectories(let parent, _) = pattern.kind {
                return parent.hasSuffix("Launcher/VaultCache")
            }
            return false
        }
    let found = try #require(entry, "the vault cache must be enumerated per asset")
    // Costly, not safe: it comes back only by re-downloading gigabytes from
    // Fab, and no manifest in any project describes what was in it.
    #expect(found.tier == .costly)
}

/// Engine-wide caches are shared by every project on the machine, which is
/// the definition of costly regardless of how automatically they refill.
@Test func unrealEngineWideCachesAreCostly() {
    for path in [
        "~/Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache",
        "~/Library/Application Support/Epic/UnrealEngine/Common/Zen/Data",
    ] {
        #expect(pattern(matchingPath: path)?.tier == .costly, "\(path)")
    }
}

/// Zen/Install holds the storage server's own binaries, not cached data.
/// Targeting the Zen directory wholesale would take the server with it.
@Test func unrealZenTargetsOnlyItsDataNotTheServerInstall() {
    #expect(pattern(matchingPath: "~/Library/Application Support/Epic/UnrealEngine/Common/Zen") == nil)
    #expect(pattern(matchingPath: "~/Library/Application Support/Epic/UnrealEngine/Common/Zen/Install") == nil)
}

/// Both live inside a versioned engine directory, so they are reached through
/// the version rather than named with one — a pattern spelling out UE_5.8
/// would stop finding anything the day the engine updates.
@Test func unrealPerVersionCachesAreReachedThroughTheVersionDirectory() throws {
    let anchors = ScanProfile.all
        .first { $0.category == .gameEngines }?
        .patterns
        .compactMap { pattern -> String? in
            if case .childSubpath(let parent, let sub, _) = pattern.kind {
                return parent.contains("Epic") ? "\(parent)/\(sub)" : nil
            }
            return nil
        } ?? []
    #expect(anchors.contains("/Users/Shared/Epic Games/Engine/DerivedDataCache"))
    #expect(anchors.contains("/Users/Shared/Epic Games/Engine/Intermediate"))
    #expect(anchors.contains(
        "~/Library/Application Support/Epic/UnrealEngine/Intermediate"))
}

/// Launcher thumbnails, refetched silently the next time the store is opened.
@Test func unrealLauncherContentCacheIsSafe() {
    #expect(
        pattern(matchingPath: "~/Library/Application Support/Epic/EpicGamesLauncher/Data/ContentCache")?
            .tier == .safe)
}

/// Project-local build artifacts, each gated on a sibling `.uproject` so that
/// a directory called Intermediate or Binaries anywhere else on the disk is
/// never offered. Safe: one deletion affects one project, and the editor
/// rebuilds them from the project itself with no download.
@Test func unrealProjectArtifactsAreGatedOnAUprojectFile() throws {
    for name in ["Intermediate", "DerivedDataCache", "Binaries"] {
        let found = try #require(pattern(matchingDirectoryNamed: name), "\(name)")
        guard case .directoryName(_, let marker) = found.kind,
              case .siblingWithExtension(let ext)? = marker
        else {
            Issue.record("\(name) must be gated on a sibling extension marker")
            continue
        }
        #expect(ext == "uproject", "\(name)")
        #expect(found.tier == .safe, "\(name)")
    }
}

/// An Unreal project's Saved/ holds Autosaves and Config beside its logs, so
/// there is no tier at which sweeping it whole is correct. It is left alone
/// entirely rather than picked apart.
@Test func noPatternSweepsAnUnrealProjectsSavedDirectory() {
    #expect(pattern(matchingDirectoryNamed: "Saved") == nil)
}

// MARK: - Unity coverage
//
// Measured on the development machine, 2026-08-29, Unity Hub with one editor,
// five asset-store publishers and one project:
//
//   ~/Library/Unity/Asset Store-5.x           1.7 GB across 5 publishers
//   ~/…/Application Support/UnityHub/Templates 336 MB
//   ~/…/Application Support/UnityHub/Cache      29 MB
//
// Everything Unity keeps under ~/Library/Caches — UnityHub (395 MB),
// com.unity3d.unityhub.ShipIt (488 MB), com.unity3d.UnityEditor (77 MB) — is
// already reached by the appCaches sweep of ~/Library/Caches and needs nothing
// here. The 28 GB of editors under /Applications/Unity/Hub is the product, not
// a cache.

/// The asset store's local copy of every package downloaded, laid out by
/// publisher. Same shape as Unreal's vault cache and costly for the same
/// reason: it refills only by re-downloading, and nothing in a project
/// describes what was in it.
@Test func unityAssetStoreDownloadsAreEnumeratedPerPublisherAtCostly() throws {
    let entry = ScanProfile.all
        .first { $0.category == .gameEngines }?
        .patterns
        .first { pattern in
            if case .subdirectories(let parent, _) = pattern.kind {
                return parent.hasSuffix("Unity/Asset Store-5.x")
            }
            return false
        }
    let found = try #require(entry, "asset store downloads must be enumerated per publisher")
    #expect(found.tier == .costly)
}

/// Templates are downloaded project scaffolds; the Hub's Cache is ordinary
/// working state it rebuilds on its own.
@Test func unityHubTemplatesAreCostlyAndItsCacheIsSafe() {
    #expect(
        pattern(matchingPath: "~/Library/Application Support/UnityHub/Templates")?
            .tier == .costly)
    #expect(
        pattern(matchingPath: "~/Library/Application Support/UnityHub/Cache")?
            .tier == .safe)
}

/// ~/Library/Unity holds the asset cache next to `licenses`, which is the
/// machine's Unity activation. A sweep of the parent would take the licence
/// with the cache and leave the editor unactivated.
@Test func noPatternSweepsTheUnityLibraryRootOrItsLicences() {
    #expect(pattern(matchingPath: "~/Library/Unity") == nil)
    #expect(pattern(matchingPath: "~/Library/Unity/licenses") == nil)
    let sweepsUnityRoot = ScanProfile.all.contains { profile in
        profile.patterns.contains { pattern in
            if case .subdirectories(let parent, _) = pattern.kind {
                return parent.hasSuffix("Library/Unity")
            }
            return false
        }
    }
    #expect(sweepsUnityRoot == false)
}

/// A Unity project's import cache — 2.0 GB on a nearly empty project, and the
/// largest thing Unity leaves anywhere. It is called `Library`, so reaching it
/// means claiming a name the walk otherwise skips; the marker demanding BOTH
/// `Assets` and `ProjectSettings` is what separates a project from `~/Library`.
///
/// Safe rather than costly: `Packages/manifest.json` in the project is exactly
/// the manifest the safe tier describes, and reopening the project rebuilds
/// the cache with no download. Slow is not the same as costly.
@Test func unityProjectImportCacheIsReachedOnlyWithBothProjectMarkers() throws {
    let found = try #require(pattern(matchingDirectoryNamed: "Library"))
    guard case .directoryName(_, let marker) = found.kind,
          case .siblingAll(let names)? = marker
    else {
        Issue.record("Library must be gated on a siblingAll marker, not a weaker one")
        return
    }
    #expect(Set(names) == ["Assets", "ProjectSettings"])
    #expect(found.tier == .safe)
}

/// Godot's per-project import cache — 1.53 GB across five projects on the
/// development machine, the largest of them 908 MB. It is what the editor
/// rebuilds by reimporting every asset when a project is opened without one,
/// and it is in every Godot .gitignore for that reason.
///
/// Gated on `project.godot`, the file that defines a Godot project and sits
/// beside the cache. Unlike Unity's `Library`, `.godot` is not a name the walk
/// skips, so this needs no traversal exemption.
///
/// Safe: one deletion affects one project and the project's own files rebuild
/// it with no download. A long reimport is slow, not costly.
@Test func godotProjectImportCachesAreGatedOnTheProjectFile() throws {
    let found = try #require(pattern(matchingDirectoryNamed: ".godot"))
    guard case .directoryName(_, let marker) = found.kind,
          case .sibling(let name)? = marker
    else {
        Issue.record(".godot must be gated on a sibling marker")
        return
    }
    #expect(name == "project.godot")
    #expect(found.tier == .safe)
}

/// One home for engine paths. The Godot, Unity and Unreal patterns were spread
/// between `appDeepClean` and `genericBuild` before this category existed, which
/// meant a user asking "why is Godot using 4 GB" had to know whether a given
/// directory was per-project or machine-wide to find it.
@Test func everyEnginePathLivesInGameEngines() {
    let engineWords = ["godot", "unity", "unreal", "epic", "uproject"]
    for profile in ScanProfile.all where profile.category != .gameEngines {
        for pattern in profile.patterns {
            let text: String
            switch pattern.kind {
            case .absolutePath(let p): text = p
            case .subdirectories(let p, _): text = p
            case .engineVersions(let p, _, _): text = p
            case .toolchainVersions(let p, _, _, _): text = p
            case .childSubpath(let p, let s, _): text = "\(p)/\(s)"
            case .directoryName(let name, let marker):
                var parts = [name]
                switch marker {
                case .sibling(let n), .child(let n), .siblingWithExtension(let n): parts.append(n)
                case .siblingAny(let ns), .siblingAll(let ns): parts += ns
                case nil: break
                }
                text = parts.joined(separator: " ")
            }
            for word in engineWords {
                #expect(
                    text.lowercased().contains(word) == false,
                    "\(profile.category.rawValue) still carries an engine path: \(text)")
            }
        }
    }
}

/// No pattern names an engine install as a fixed path. Godot.app and Unreal's
/// engine directory are the product, and the Uninstall view is where an
/// installed thing is removed.
///
/// Unity's editor root is the deliberate exception and is not an exception to
/// this rule: it is reached by `.engineVersions`, which offers only versions
/// nothing retains, never the editor in use. A fixed path under /Applications
/// would offer whatever is there.
@Test func gameEnginesNamesNoEngineInstallAsAFixedPath() throws {
    let profile = try #require(ScanProfile.all.first { $0.category == .gameEngines })
    for pattern in profile.patterns {
        guard case .absolutePath(let path) = pattern.kind else { continue }
        #expect(path.hasSuffix(".app") == false, "\(path)")
        #expect(path.hasPrefix("/Applications") == false, "\(path)")
    }
    // And the one engine root that IS reached is reached the version-aware way.
    let unityRoots = profile.patterns.compactMap { pattern -> String? in
        if case .engineVersions(let parent, let engine, _) = pattern.kind, engine == .unity {
            return parent
        }
        return nil
    }
    #expect(unityRoots == ["/Applications/Unity/Hub/Editor"])
}

/// Unreal keeps a support directory per engine version, and upgrading leaves
/// the old one. Measured while 5.8 was installing: a `5.5` directory survived
/// from an install long gone.
///
/// The sibling `Common` directory in the same parent carries no version, so
/// `EngineVersions` never offers it -- the fail-closed rule doing real work
/// rather than being merely asserted, since Common holds the shared derived
/// data cache and Zen store for whatever engine IS installed.
@Test func unrealPerVersionSupportIsOfferedOnlyForUninstalledEngines() throws {
    let entry = ScanProfile.all
        .first { $0.category == .gameEngines }?
        .patterns
        .first { pattern in
            if case .engineVersions(let parent, _, _) = pattern.kind {
                return parent.hasSuffix("Epic/UnrealEngine")
            }
            return false
        }
    let found = try #require(entry, "per-version Unreal support must be version-aware")
    guard case .engineVersions(_, let engine, _) = found.kind else {
        Issue.record("expected an engineVersions pattern")
        return
    }
    #expect(engine == .unreal)
    #expect(found.tier == .costly)
}
