import Testing
import Foundation
@testable import DDCCCore

// MARK: - Fixture helpers

/// Creates a minimal `.app` bundle that `InstalledApps.scan` can read an
/// identifier out of. Mirrors `FootprintAssemblerTests`' own helper — kept
/// duplicated per-file rather than shared, matching that file's own choice
/// to keep fixture helpers file-private.
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

/// Writes a LaunchAgent plist whose `Program` names `target` — an absolute
/// path that does not exist, so `DependencyProbe.classify(launchAgentAt:)`
/// reads it as `.dead`.
@discardableResult
private func makeDeadLaunchAgent(
    _ tree: FixtureTree, at relativePath: String, target: String
) throws -> URL {
    let url = try tree.file(relativePath)
    let plist: [String: Any] = ["Label": "dead", "Program": target]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url)
    return url
}

// MARK: - One row per identity, one row per dead artifact

/// One row per app identity, present or absent, plus dead artifacts on
/// their own rows because they belong to no live identity — that is what
/// makes them dead.
@Test func theSweepProducesOneRowPerIdentityAndOneForEachDeadArtifact() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(tree, at: "Applications/One.app", bundleID: "com.example.one", displayName: "One")
        try makeAppBundle(tree, at: "Applications/Two.app", bundleID: "com.example.two", displayName: "Two")
        try tree.file("Library/Preferences/com.example.one.plist", byteCount: 64)

        // A LaunchAgent whose declared executable is gone — the one dead
        // artifact this fixture plants.
        try makeDeadLaunchAgent(
            tree, at: "Library/LaunchAgents/com.example.stale.plist",
            target: library.appendingPathComponent("nonexistent-helper").path)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let deadRows = report.rows.compactMap { row -> FootprintItem? in
            guard case .deadArtifact(let item) = row else { return nil }
            return item
        }

        #expect(appRows.count == 2)
        #expect(Set(appRows.map(\.identity.bundleID)) == ["com.example.one", "com.example.two"])

        #expect(deadRows.count == 1)
        let dead = try #require(deadRows.first)
        #expect(dead.evidence == .dead(target: library.appendingPathComponent("nonexistent-helper").path))
        #expect(dead.sources == [.launchAgent])
    }
}

// MARK: - Dead-artifact refusals are disclosed, not dropped

/// binds the dead-artifact sweep exactly as it binds
/// `FootprintAssembler`: a `PathGuard` refusal is disclosed, never silently
/// dropped. `PathGuard` refuses a path that is itself a symbolic link — the
/// same shape `FootprintAssemblerTests
/// .aPathTheGuardRefusesInsideTheAllowlistIsDisclosedNotDropped` uses, and a
/// realistic one: `PathGuard.isRootOwned` fires identically for a pkg-owned
/// LaunchAgent plist, which this fixture cannot construct without root, but
/// the guard call and its disclosure path are the same regardless of which
/// reason fires.
@Test func aGuardRefusedDeadArtifactIsDisclosedNotDropped() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        let real = try makeDeadLaunchAgent(
            tree, at: "elsewhere/real.plist",
            target: library.appendingPathComponent("nonexistent-helper").path)
        let link = try tree.symlink("Library/LaunchAgents/com.example.symlinked.plist", to: real)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false })

        // Not silently dropped into an ordinary row...
        let deadRows = report.rows.compactMap { row -> FootprintItem? in
            guard case .deadArtifact(let item) = row else { return nil }
            return item
        }
        #expect(deadRows.isEmpty)

        // ...but disclosed, and reachable from the report's one union.
        let key = Candidate.normalizedPathKey(for: link)
        #expect(report.deadArtifactGuardRefusals.map(\.path) == [key])
        #expect(report.pathGuardRefusals.map(\.path).contains(key))
    }
}

// MARK: - Disclosed evidence gaps

/// The honesty half, reusing the model the Caches view already uses. An
/// absent Homebrew cache is not an error; it is a disclosed gap in the
/// evidence, and the difference between "we found everything" and "we found
/// everything we could look for".
@Test func anAbsentEvidenceSourceIsDisclosedRatherThanIgnored() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try makeAppBundle(tree, at: "Applications/Solo.app", bundleID: "com.example.solo", displayName: "Solo")

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        // No Homebrew cask cache on this machine — the common case.
        let absent = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { [] }, applicationGroups: { _ in [] }, isRunning: { _ in false })
        #expect(absent.unavailableSources.contains("Homebrew cask cache"))

        // Positive control: a present cask index discloses nothing missing.
        let caskURL = root.appendingPathComponent("cask.jws.json")
        let payload = try JSONSerialization.data(
            withJSONObject: ["payload": "[]", "signatures": []])
        try payload.write(to: caskURL)
        let present = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
            // Pinned rather than defaulted: `receiptsReadable` reads the
            // host's own `/var/db/receipts`, so a sweep that resolves a cask
            // presence would answer differently on a machine that cannot
            // open it. `true` states that the receipts named above are the
            // whole database.
            receiptsReadable: { true },
            caskIndex: { CaskIndex.load(from: caskURL) }, caskroomTokens: { [] },
            // The other host read in the same presence context: left to its
            // default this enumerates `/opt`, `/Users/Shared` and `/Volumes`
            // on the machine running the test.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: { _ in [] }, isRunning: { _ in false })
        #expect(!present.unavailableSources.contains("Homebrew cask cache"))
    }
}

// MARK: - Completeness and PathGuard-refusal aggregation

/// `completeness` is a genuine measurement, not a hardcoded `.exact`: a
/// directory this sweep could not fully read while sizing an app's own
/// container must show up as incompleteness on the report, the same
/// `ScanCompleteness` contract the Caches pipeline already honors.
@Test func completenessReflectsAPathThisSweepCouldNotFullyRead() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try makeAppBundle(
            tree, at: "Applications/Leaky.app", bundleID: "com.example.leaky", displayName: "Leaky")

        let locked = try tree.directory("Library/Containers/com.example.leaky/locked")
        try tree.file("Library/Containers/com.example.leaky/locked/secret.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
        }

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false })

        #expect(!report.completeness.isExact)
        #expect(report.completeness.unreadableDirectories >= 1)
    }
}

/// `pathGuardRefusals` is the report-level union ruling 19 requires: every
/// app row's own `refusedByPathGuard` must actually surface here, not just
/// exist unread on the row.
@Test func pathGuardRefusalsAggregatesDisclosuresFromAppRows() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try makeAppBundle(
            tree, at: "Applications/Linked.app", bundleID: "com.example.linked", displayName: "Linked")

        let real = try tree.file("elsewhere/real.plist", byteCount: 512)
        try tree.directory("Library/Preferences")
        let link = try tree.symlink("Library/Preferences/com.example.linked.plist", to: real)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false })

        let key = Candidate.normalizedPathKey(for: link)
        #expect(report.pathGuardRefusals.map(\.path).contains(key))
    }
}

// MARK: - Unattributed bytes

/// Bytes a receipt declares for a package no swept identity claims must be
/// reported on their own, never folded into any app's row.
///
/// The orphan here is Apple-owned deliberately: a non-Apple orphan receipt is
/// exactly the shape `RecoveredIdentities` recovers into its own row, so
/// asserting one stays unattributed would test that recovery rather than this
/// figure's own exclusion. Apple's namespace is refused by both mechanisms
/// (`FootprintAssembler.assemble`'s `.appleOwned` refusal, and
/// `RecoveredIdentities`'s own `isAppleOwned` guard), so it is the one receipt
/// shape guaranteed to remain genuinely unattributed.
@Test func bytesThatCouldNotBeAttributedAreReportedSeparatelyNotAsAnyAppsBytes() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        // No app on disk claims this package id — a pkg install for
        // software already dragged to the Trash, receipt still on record.
        try tree.file("Library/Application Support/Orphan/data", byteCount: 4096)
        let orphanReceipt = Receipt(packageID: "com.apple.pkg.orphan", installPrefix: "/", bomURL: nil)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let orphanPathKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Orphan"))

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [orphanReceipt], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { receipt in
                receipt.packageID == "com.apple.pkg.orphan" ? [orphanPathKey] : nil
            })

        #expect(report.unattributedBytes >= 4096)

        // Not any app's bytes: with no installed identity at all, there are
        // no `.app` rows for these bytes to have leaked into.
        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        #expect(appRows.isEmpty)
        var totalAppBytes: Int64 = 0
        for footprint in appRows { totalAppBytes += footprint.reclaimableBytes }
        #expect(totalAppBytes == 0)
    }
}

/// Package ids and bundle ids are separate namespaces, so a receipt
/// routinely fails the package-id match while its declared paths are
/// simultaneously claimed by a live app through container or shelf
/// evidence. A fixture with zero installed apps cannot exercise this —
/// see the project's own "one is not enough to count" lesson — so this one
/// installs a real app whose container a *different*, non-matching receipt
/// also names, alongside a genuinely orphaned receipt with no such overlap.
///
/// Both receipts are Apple-owned for the same reason
/// `bytesThatCouldNotBeAttributedAreReportedSeparatelyNotAsAnyAppsBytes`'s
/// own receipt is: a non-Apple receipt matching no identity is exactly what
/// `RecoveredIdentities` recovers into its own row, which would make each of
/// these two start a competing row rather than testing this figure's own
/// exclusion.
@Test func unattributedBytesExcludesPathsAnAppRowAlreadyAttributes() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Claimed.app", bundleID: "com.example.claimed", displayName: "Claimed")
        let containerPath = try tree.directory("Library/Containers/com.example.claimed")
        try tree.file("Library/Containers/com.example.claimed/blob", byteCount: 4096)

        // A receipt for an unrelated package id that happens to declare the
        // exact same path the live app's own container evidence already
        // attributes.
        let overlappingReceipt = Receipt(
            packageID: "com.apple.pkg.unrelated", installPrefix: "/", bomURL: nil)
        let overlappingKey = Candidate.normalizedPathKey(for: containerPath)

        // A genuinely orphaned receipt: no assembled identity, and no row
        // names this path at all.
        try tree.file("Library/Application Support/Orphan/data", byteCount: 2048)
        let orphanReceipt = Receipt(packageID: "com.apple.pkg.trulyorphan", installPrefix: "/", bomURL: nil)
        let orphanKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Orphan"))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env,
            receipts: { (receipts: [overlappingReceipt, orphanReceipt], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { receipt in
                switch receipt.packageID {
                case "com.apple.pkg.unrelated": return [overlappingKey]
                case "com.apple.pkg.trulyorphan": return [orphanKey]
                default: return nil
                }
            })

        let orphanBytes = try #require(SizeCalculator.measure(
            at: library.appendingPathComponent("Application Support/Orphan")).measurement?.bytes)

        // The overlapping receipt's bytes are excluded: they are already
        // counted inside Claimed's own row, and summing them again here
        // would double them.
        #expect(report.unattributedBytes == orphanBytes)

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let claimed = try #require(appRows.first { $0.identity.bundleID == "com.example.claimed" })
        #expect(claimed.reclaimableBytes >= 4096)
    }
}

/// The identical escape `FootprintAssembler`'s resolved re-check closes,
/// reopened one file away if the allowlist check here stayed lexical-only.
/// `~/Library/Application Support/Foo` is a symlink to `~/Dropbox/Foo`; its
/// descendant `Foo/bar` is not itself a symlink, so a lexical-only check
/// admits it, and measuring it recursively would fold `~/Dropbox` bytes into
/// `unattributedBytes`. The resolved re-check must stop it before that
/// measurement happens.
@Test func unattributedReceiptBytesDoesNotFollowASymlinkedAncestorOutOfTheAllowlist() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let outside = try tree.directory("Dropbox/Foo")
        try tree.file("Dropbox/Foo/bar/blob", byteCount: 4096)
        try tree.directory("Library/Application Support")
        try tree.symlink("Library/Application Support/Foo", to: outside)

        let descendantKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/Foo/bar"))
        let escapingReceipt = Receipt(packageID: "com.example.escape", installPrefix: "/", bomURL: nil)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [escapingReceipt], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in [descendantKey] })

        #expect(report.unattributedBytes == 0)
    }
}

// MARK: - Identities recovered from evidence

/// Wraps a cask array as the JWS envelope `CaskIndex.load` expects. Same
/// shape every other file's own fixture helper uses.
private func writeCaskFixtureForCoordinator(_ casks: String, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: ["payload": casks, "signatures": []])
    try data.write(to: url)
}

/// the disclosure, pinned: when neither Caskroom prefix could be
/// read, `unavailableSources` must say so — that disclosure is the entire
/// safety valve behind "never fall back to the catalog," and nothing would
/// fail if the branch producing it were deleted before this test existed.
@Test func aCaskroomThatCannotBeReadIsDisclosedInUnavailableSources() async throws {
    try await withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let unreadable = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false })
        #expect(unreadable.unavailableSources.contains("Homebrew Caskroom"))

        // Positive control: a readable-but-empty Caskroom discloses nothing
        // missing — the same "unreadable is not the same as empty"
        // distinction `installedCaskTokens` itself keeps.
        let readable = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { [] }, applicationGroups: { _ in [] }, isRunning: { _ in false })
        #expect(!readable.unavailableSources.contains("Homebrew Caskroom"))
    }
}

/// Evidence, not inference: the OS's own record of an install names a
/// package that no installed app answers for, and its leftovers are the
/// whole reason this feature exists.
@Test func anAppGoneFromDiskButNamedByAReceiptGetsItsOwnRow() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        // The app itself is gone — nothing under Applications names it —
        // but its receipt still declares this leftover.
        try tree.file("Library/Application Support/GhostVendor/data", byteCount: 4096)
        let ghostKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/GhostVendor"))
        let ghostReceipt = Receipt(packageID: "com.example.ghost", installPrefix: "/", bomURL: nil)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [ghostReceipt], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { receipt in
                receipt.packageID == "com.example.ghost" ? [ghostKey] : nil
            })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let ghost = try #require(appRows.first { $0.identity.bundleID == "com.example.ghost" })
        #expect(ghost.identity.isPresent == false)
        #expect(ghost.reclaimableBytes >= 4096)
    }
}

/// Homebrew's record, the other evidence source. A cask naming an `.app`
/// that is no longer on disk is a recovered identity, not a guess.
@Test func anAppGoneFromDiskButNamedByACaskGetsItsOwnRow() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        // No `.app` on disk anywhere — the cask's own record is the only
        // evidence this identity ever existed.
        try tree.file("Library/Application Support/GhostApp/data", byteCount: 8192)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          {
            "token": "ghost-app",
            "artifacts": [
              { "app": ["Ghost.app"] },
              { "zap": [{ "trash": ["\(support.path)/GhostApp"] }] }
            ]
          }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
            // Pinned rather than defaulted: `receiptsReadable` reads the
            // host's own `/var/db/receipts`, so a sweep that resolves a cask
            // presence would answer differently on a machine that cannot
            // open it. `true` states that the receipts named above are the
            // whole database.
            receiptsReadable: { true },
            caskIndex: { caskIndex }, caskroomTokens: { ["ghost-app"] },
            // The other host read in the same presence context: left to its
            // default this enumerates `/opt`, `/Users/Shared` and `/Volumes`
            // on the machine running the test.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let ghost = try #require(appRows.first { $0.identity.bundleID == "ghost-app" })
        #expect(ghost.identity.isPresent == false)
        #expect(ghost.reclaimableBytes >= 8192)
    }
}

/// A recovered identity has no bundle to read entitlements from, so it
/// cannot vouch for a shared path the way a scanned app can. `Real.app` is
/// genuinely installed and genuinely declares the shared group via the
/// `applicationGroups` stub; the stub answers identically for *any* bundle
/// URL, including the cask-recovered ghost's synthetic one, so the only
/// thing standing between the ghost's row and an unearned claim on that
/// shared container is `isPresent` actually gating the call.
@Test func aRecoveredIdentityIsNotCountedAsAClaimantOfASharedPath() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Real.app", bundleID: "com.example.real", displayName: "Real")
        try tree.file("Library/Group Containers/com.example.sharedgroup/blob", byteCount: 2048)

        // The ghost's own, unrelated leftover — so its row is non-empty for
        // a reason that has nothing to do with the shared container.
        try tree.file("Library/Application Support/GhostApp/data", byteCount: 4096)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          {
            "token": "ghost-app",
            "artifacts": [
              { "app": ["Ghost.app"] },
              { "zap": [{ "trash": ["\(support.path)/GhostApp"] }] }
            ]
          }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        // Answers non-empty for *any* bundle URL — a stand-in for "if this
        // ever got called for a recovered identity, it would not fail
        // closed on its own."
        let anyBundleClaimsTheSharedGroup: @Sendable (URL) -> Set<String> = { _ in ["com.example.sharedgroup"] }

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
            // Pinned rather than defaulted: `receiptsReadable` reads the
            // host's own `/var/db/receipts`, so a sweep that resolves a cask
            // presence would answer differently on a machine that cannot
            // open it. `true` states that the receipts named above are the
            // whole database.
            receiptsReadable: { true },
            caskIndex: { caskIndex }, caskroomTokens: { ["ghost-app"] },
            // The other host read in the same presence context: left to its
            // default this enumerates `/opt`, `/Users/Shared` and `/Volumes`
            // on the machine running the test.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: anyBundleClaimsTheSharedGroup, isRunning: { _ in false })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let ghost = try #require(appRows.first { $0.identity.bundleID == "ghost-app" })

        // The ghost's own leftover is still there...
        #expect(ghost.reclaimableBytes >= 4096)
        // ...but the shared group container it has no entitlement to read
        // never appears on its row at all, retained or otherwise.
        let sharedKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Group Containers/com.example.sharedgroup"))
        #expect(!ghost.retained.contains { $0.id == sharedKey })
        #expect(!ghost.items.contains { $0.id == sharedKey })

        // Positive control: `Real.app`, which genuinely has the
        // entitlement, does see the container as its own and reclaimable
        // (nothing else claims it) — so the ghost's absence above is the
        // `isPresent` gate, not an empty fixture.
        let real = try #require(appRows.first { $0.identity.bundleID == "com.example.real" })
        #expect(real.items.contains { $0.id == sharedKey })
    }
}

/// The same guarantee for the one recovered identity that is **present**. A
/// cask anchored on a matching `pkgutil` receipt names a product that really is
/// installed, so the `isPresent` gate above does not cover it — and must not
/// have to. What covers it is that the identity carries no `bundleURL` at all,
/// which `ClaimantIndex.discoverGroupContainerEvidence` refuses before it reads
/// any entitlement. This fails the moment such an identity is given a bundle
/// path, synthetic or otherwise, while staying present.
@Test func aPresentReceiptAnchoredCaskIsNotCountedAsAClaimantOfASharedPath() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsRoot, withIntermediateDirectories: true)

        try tree.file("Library/Group Containers/com.example.sharedgroup/blob", byteCount: 2048)
        try tree.file("Library/Application Support/VendorTool/data", byteCount: 4096)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          {
            "token": "vendor-tool",
            "artifacts": [
              { "uninstall": [{ "pkgutil": "com\\\\.example\\\\.vendortool" }] },
              { "zap": [{ "trash": ["\(support.path)/VendorTool"] }] }
            ]
          }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
        let anyBundleClaimsTheSharedGroup: @Sendable (URL) -> Set<String> = { _ in ["com.example.sharedgroup"] }

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env,
            receipts: { (receipts: [Receipt(packageID: "com.example.vendortool", installPrefix: "/", bomURL: nil)], fullyRead: true) },
            // Pinned rather than defaulted: `receiptsReadable` reads the
            // host's own `/var/db/receipts`, so a sweep that resolves a cask
            // presence would answer differently on a machine that cannot
            // open it. `true` states that the receipts named above are the
            // whole database.
            receiptsReadable: { true },
            caskIndex: { caskIndex }, caskroomTokens: { [] },
            // The other host read in the same presence context: left to its
            // default this enumerates `/opt`, `/Users/Shared` and `/Volumes`
            // on the machine running the test.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: anyBundleClaimsTheSharedGroup, isRunning: { _ in false })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let recovered = try #require(appRows.first { $0.identity.bundleID == "vendor-tool" })
        #expect(recovered.identity.isPresent)
        #expect(recovered.reclaimableBytes >= 4096)

        let sharedKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Group Containers/com.example.sharedgroup"))
        #expect(!recovered.retained.contains { $0.id == sharedKey })
        #expect(!recovered.items.contains { $0.id == sharedKey })
    }
}

/// Not a new mechanism — proof that the existing one actually fires
/// once these rows exist. The receipt's bytes are counted once, inside the
/// recovered identity's own row, and never a second time as unattributed.
@Test func bytesOnARecoveredIdentitysRowLeaveTheUnattributedTotal() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try tree.file("Library/Application Support/GhostVendor/data", byteCount: 4096)
        let ghostKey = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/GhostVendor"))
        let ghostReceipt = Receipt(packageID: "com.example.ghost", installPrefix: "/", bomURL: nil)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [ghostReceipt], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { receipt in
                receipt.packageID == "com.example.ghost" ? [ghostKey] : nil
            })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let ghost = try #require(appRows.first { $0.identity.bundleID == "com.example.ghost" })
        #expect(ghost.reclaimableBytes >= 4096)

        // The ghost's own leftover is inside its row, not floating in the
        // unattributed pool a second time.
        #expect(report.unattributedBytes == 0)
    }
}

// MARK: - Cancellation

/// `SizeCalculator` checks `Task.isCancelled` and `SizeCompletenessAccumulator`
/// folds `.cancelled` into `unmeasuredItems`, but the loop around them did
/// not check anything — so a cancelled sweep still called `assemble` for
/// every remaining identity and took as long as letting it finish. Stop
/// only means something if the loop stops.
///
/// Cancelled deterministically from inside the run rather than by racing a
/// `task.cancel()` against the scheduler: `onPhase` fires on the
/// coordinator's own task at the top of each identity, so cancelling there
/// lands after the first identity is assembled and before the second is
/// reached. Three identities, so "stopped after the first" is
/// distinguishable from both "stopped immediately" and "ran to the end".
@Test func aCancelledSweepStopsAssemblingAndReportsItselfIncomplete() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(tree, at: "Applications/A.app", bundleID: "com.example.a", displayName: "A")
        try makeAppBundle(tree, at: "Applications/B.app", bundleID: "com.example.b", displayName: "B")
        try makeAppBundle(tree, at: "Applications/C.app", bundleID: "com.example.c", displayName: "C")

        // A dead artifact that a completed sweep would find, so its absence
        // here proves the dead-artifact walk was skipped rather than merely
        // having found nothing.
        try makeDeadLaunchAgent(
            tree, at: "Library/LaunchAgents/com.example.stale.plist",
            target: library.appendingPathComponent("nonexistent-helper").path)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false },
            onPhase: { phase in
                guard case .assembling = phase else { return }
                withUnsafeCurrentTask { $0?.cancel() }
            })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let deadRows = report.rows.compactMap { row -> FootprintItem? in
            guard case .deadArtifact(let item) = row else { return nil }
            return item
        }

        // One identity assembled, the other two never reached.
        #expect(appRows.count == 1)
        #expect(deadRows.isEmpty)

        // And the report says so. A stopped run that rendered as exact
        // would assert a completeness it never checked.
        #expect(!report.completeness.isExact)
        // Two unreached identities plus the skipped dead-artifact walk.
        #expect(report.completeness.unmeasuredItems >= 3)
    }
}

/// The same run without cancellation, so the test above is pinning
/// cancellation rather than a fixture that was always going to come out
/// short. Same tree, same providers, no `cancel()`.
@Test func anUncancelledSweepOfTheSameTreeIsExactAndComplete() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(tree, at: "Applications/A.app", bundleID: "com.example.a", displayName: "A")
        try makeAppBundle(tree, at: "Applications/B.app", bundleID: "com.example.b", displayName: "B")
        try makeAppBundle(tree, at: "Applications/C.app", bundleID: "com.example.c", displayName: "C")
        try makeDeadLaunchAgent(
            tree, at: "Library/LaunchAgents/com.example.stale.plist",
            target: library.appendingPathComponent("nonexistent-helper").path)

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) }, caskIndex: { nil },
            caskroomTokens: { nil }, applicationGroups: { _ in [] }, isRunning: { _ in false })

        let appRows = report.rows.filter { if case .app = $0 { return true } else { return false } }
        let deadRows = report.rows.filter { if case .deadArtifact = $0 { return true } else { return false } }
        #expect(appRows.count == 3)
        #expect(deadRows.count == 1)
        #expect(report.completeness.unmeasuredItems == 0)
    }
}

// MARK: - The presence context actually reaches the assembler

/// The sweep must hand `FootprintAssembler` a real `CaskPresence`, not
/// `nil`. Every other test of this mechanism calls `CaskIndex` directly and
/// would pass identically against a coordinator that resolved presence and
/// then forgot to pass it — which is exactly how `DeclaredPayloadSource`
/// was resolved and dropped once before.
///
/// Pinned behaviourally, not by inspection: `Application Support/Shared` is
/// declared by both `host` and `absent-rival`, so catalogue-wide Rule 3
/// refuses it. `Gone.app` is not on this fixture's disk, so a resolved
/// presence proves the rival absent and releases the path. If the
/// coordinator passes `nil`, the rival keeps refusing and the row is empty.
@Test func theSweepPassesAResolvedCaskPresenceToTheAssembler() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host",
            displayName: "Host")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "absent-rival", "artifacts": [
              { "app": ["Gone.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        // Negative control, run through the same index the sweep gets: with
        // no machine context the shared root is refused outright, so a
        // passing assertion below can only come from a real presence.
        #expect(caskIndex.zapPaths(
            forAppBundleNamed: "Host.app", presence: nil).isEmpty)

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
            receiptsReadable: { true },
            caskIndex: { caskIndex }, caskroomTokens: { [] },
            // The presence context's other host read, pinned for the
            // same reason `receiptsReadable` is: its default enumerates
            // `/opt`, `/Users/Shared` and `/Volumes` on the machine
            // running the test.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let appRows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let host = try #require(appRows.first { $0.identity.bundleID == "com.example.host" })
        #expect(host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") })
    }
}

/// Writes a `.app` whose `Info.plist` declares no `CFBundleIdentifier`, so
/// `InstalledApps.scan` discovers the bundle but drops it from `byID` — the
/// partial-tolerance the scan is built for.
@discardableResult
private func makeUnidentifiedAppBundle(
    _ tree: FixtureTree, at relativePath: String, displayName: String
) throws -> URL {
    let bundleURL = try tree.directory(relativePath)
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleName": displayName], format: .xml, options: 0)
    try tree.directory(relativePath + "/Contents")
    try data.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    return bundleURL
}

/// A rival whose bundle is on disk but whose `Info.plist` could not be read
/// must keep refusing the shared root. `InstalledApps.scan` skips such a
/// bundle when building `byID`, so a presence context sourced from `byID`
/// would call the rival provably absent and hand a live product's directory
/// to its neighbour — a parse failure read as an uninstall. The filenames
/// come from the disk walk instead, which cannot lose a bundle it found.
///
/// Guarded against passing vacuously: the same fixture with `Broken.app`
/// deleted must release the path, so the refusal below can only come from
/// the bundle being there.
@Test func aRivalOnDiskWithAnUnreadableIdentifierStillRefusesTheSharedRoot() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        let brokenURL = try makeUnidentifiedAppBundle(
            tree, at: "Applications/Broken.app", displayName: "Broken")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "broken-vendor", "artifacts": [
              { "app": ["Broken.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)

        func sharedRootOffered() async throws -> Bool {
            let apps = InstalledApps.scan(
                roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
                receiptsReadable: { true },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                // The presence context's other host read, pinned for the
                // same reason `receiptsReadable` is: its default enumerates
                // `/opt`, `/Users/Shared` and `/Volumes` on the machine
                // running the test.
                appFilenamesOutsideScanRoots: { ([], true) },
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // `Broken.app` is on disk, so the rival is not absent and the shared
        // root stays refused — even though nothing could read its identifier.
        #expect(try await sharedRootOffered() == false)

        // Control: with the bundle actually gone, the same fixture releases
        // it. The refusal above is caused by the bundle, not by the fixture.
        try FileManager.default.removeItem(at: brokenURL)
        #expect(try await sharedRootOffered() == true)
    }
}

/// An unreadable receipt database must prove no cask absent. A cask with no
/// `app` artifact is anchored only by its `pkgutil` pattern, so the receipts
/// are its one positive test: read and empty, that test ran and failed and
/// the cask is absent; unreadable, nothing ran and the refusal must stand.
/// `receipts(in:)` returns `[]` for both, which is why `receiptsReadable` is
/// a separate seam — and why passing `[]` rather than `nil` here would mark
/// every pkgutil-only cask absent on a machine that simply could not look.
@Test func anUnreadableReceiptDatabaseProvesNoPkgutilOnlyCaskAbsent() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "pkg-only-rival", "artifacts": [
              { "zap": [
                  { "trash": "\(support.path)/Shared", "pkgutil": "com.example.pkgonly" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))
        // The rival really is anchored on a receipt id and nothing else.
        #expect(caskIndex.receiptPatterns(forCaskToken: "pkg-only-rival") == ["com.example.pkgonly"])

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(
            roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        func sharedRootOffered(receiptsReadable: Bool) async throws -> Bool {
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
                receiptsReadable: { receiptsReadable },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                // The presence context's other host read, pinned for the
                // same reason `receiptsReadable` is: its default enumerates
                // `/opt`, `/Users/Shared` and `/Volumes` on the machine
                // running the test.
                appFilenamesOutsideScanRoots: { ([], true) },
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // Nothing could be read, so nothing was proved. Refusal stands.
        #expect(try await sharedRootOffered(receiptsReadable: false) == false)

        // Control: the same empty receipt list, read successfully, IS a
        // finding — so the refusal above comes from the unreadability, not
        // from the fixture being unable to release anything.
        #expect(try await sharedRootOffered(receiptsReadable: true) == true)
    }
}

/// A scan that enumerated nothing must prove no app-declaring cask absent.
/// The sweep still produces rows in that state — a recovered identity needs
/// no bundle on disk — so the empty set reaches `CaskPresence` and, taken
/// literally, would mark every cask with an `app` artifact absent on the
/// strength of a walk that found nothing to compare against. Passing `nil`
/// instead is the same fail-closed reading the receipt database gets.
@Test func aScanThatFoundNoBundlesProvesNoAppDeclaringCaskAbsent() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)

        try tree.file("Library/Application Support/Shared/data", byteCount: 8192)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "ghost-app", "artifacts": [
              { "app": ["Ghost.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "other-ghost", "artifacts": [
              { "app": ["Other.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        // No roots at all: discovery returns nothing, which is the state
        // under test — not a machine known to hold zero applications.
        let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })
        #expect(apps.discoveredBundleFilenames.isEmpty)

        let report = await UninstallCoordinator().run(
            installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
            receiptsReadable: { true },
            caskIndex: { caskIndex }, caskroomTokens: { ["ghost-app"] },
            // The other half of the presence filenames, pinned empty for the
            // same reason the roots are: this test is about an enumeration
            // that found nothing, and the machine running it must not be
            // allowed to supply the filenames that would end that state.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: { _ in [] }, isRunning: { _ in false })

        let rows = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let ghost = try #require(rows.first { $0.identity.bundleID == "ghost-app" })
        #expect(!ghost.items.contains { $0.path.path.hasSuffix("Application Support/Shared") })
    }
}

/// A cask with no `app` artifact, anchored on a receipt, must reach the
/// swept result as a row with its declared paths attached. The unit tests
/// on either side of this seam each pass while this fails — one mints an
/// identity nothing asks about, the other answers a question nothing poses.
@Test func aReceiptAnchoredCaskAppearsInTheSweepWithItsDeclaredPaths() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(
            at: appsRoot, withIntermediateDirectories: true)
        try tree.file("Library/Application Support/AutoUpdate/marker", byteCount: 2)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "auto-update", "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.autoupdate" } ] },
              { "zap": [ { "trash": "\(library.path)/Application Support/AutoUpdate" } ] } ] }
        ]
        """, to: caskURL)

        let report = await UninstallCoordinator().run(
            installedApps: {
                InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
            },
            environment: ScanEnvironment(libraryURL: library),
            receipts: {
                (receipts: [Receipt(packageID: "com.example.autoupdate",
                                    installPrefix: "/", bomURL: nil)],
                 fullyRead: true)
            },
            receiptsReadable: { true },
            caskIndex: { CaskIndex.load(from: caskURL) },
            caskroomTokens: { [] },
            // The presence context's other host read, pinned for the same
            // reason `receiptsReadable` is: its default enumerates `/opt`,
            // `/Users/Shared` and `/Volumes` on the machine running the test.
            appFilenamesOutsideScanRoots: { ([], true) },
            applicationGroups: { _ in [] }, isRunning: { _ in false },
            receiptPaths: { _ in [] })

        let footprints = report.rows.compactMap { row -> AppFootprint? in
            guard case .app(let footprint) = row else { return nil }
            return footprint
        }
        let row = try #require(footprints.first { $0.identity.bundleID == "auto-update" })

        let declared = Candidate.normalizedPathKey(
            for: library.appendingPathComponent("Application Support/AutoUpdate"))
        #expect(row.items.contains { Candidate.normalizedPathKey(for: $0.path) == declared })
    }
}

/// An app outside the scan roots must not make its own cask read as
/// provably absent. Discovery is bounded by four roots, so a bundle in
/// `/opt`, `/Users/Shared` or on an external volume is in neither `byID`
/// nor `discoveredBundleFilenames` — and a cask whose `app` artifact names
/// it then fails its one positive test and is proved absent, releasing a
/// shared directory the live product still uses.
///
/// The presence question is asked against a wider sweep than the one that
/// mints uninstall rows. Widening it can only add filenames, so it can only
/// add refusals; which apps get their own row is untouched.
///
/// Guarded against passing vacuously: the same fixture with the outside
/// location not swept must release the path, so the refusal below can only
/// come from the wider sweep.
@Test func anAppOutsideTheScanRootsStillRefusesTheSharedRoot() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        let elsewhere = root.appendingPathComponent("opt", isDirectory: true)

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        try makeAppBundle(
            tree, at: "opt/Outside.app", bundleID: "com.example.outside", displayName: "Outside")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "outside-vendor", "artifacts": [
              { "app": ["Outside.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
        // The rival really is invisible to the roots that mint rows.
        #expect(!apps.discoveredBundleFilenames.contains("Outside.app"))

        func sharedRootOffered(sweeping presenceRoots: [URL]) async throws -> Bool {
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
                receiptsReadable: { true },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                appFilenamesOutsideScanRoots: {
                    InstalledApps.bundleFilenames(directlyUnder: presenceRoots)
                },
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // Swept, so the rival is present and the shared root stays refused.
        #expect(try await sharedRootOffered(sweeping: [elsewhere]) == false)

        // Control: nothing outside the roots is looked at, and the same
        // fixture releases it. The refusal above comes from the sweep.
        #expect(try await sharedRootOffered(sweeping: []) == true)

        // A root that cannot be listed contributes nothing rather than
        // throwing — and contributing nothing is the releasing direction,
        // which is why this is a supplement to the scan, not a substitute.
        #expect(InstalledApps.bundleFilenames(
            directlyUnder: [root.appendingPathComponent("no-such-directory")])
            .filenames.isEmpty)
        #expect(InstalledApps.bundleFilenames(directlyUnder: [elsewhere])
            .filenames == ["Outside.app"])
    }
}

/// A presence sweep that could not finish must not prove any cask absent.
///
/// The sweep gives each root a deadline, so a stalled network mount cannot
/// hang the scan — but a root that ran out of time contributes no filenames,
/// and a missing filename is exactly what proves a cask absent and releases
/// the paths it was refusing. The abandoned listing has to reach the presence
/// resolver as "this sweep is short", not as "these are the apps on this
/// machine".
///
/// Forced here by a sweep root that outlasts its deadline while the scan roots
/// answer normally, which is the case an "is the union empty?" test cannot
/// see: the union is not empty, because `Host.app` is in it.
///
/// Guarded against passing vacuously by the control below: the same fixture
/// with a sweep that did finish releases the shared root, so the refusal comes
/// from the incomplete sweep and not from the fixture.
@Test func aPresenceSweepThatCouldNotFinishDoesNotProveACaskAbsent() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        let elsewhere = root.appendingPathComponent("opt", isDirectory: true)

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        try makeAppBundle(
            tree, at: "opt/Outside.app", bundleID: "com.example.outside", displayName: "Outside")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "outside-vendor", "artifacts": [
              { "app": ["Outside.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
        // The scan roots really do answer, so the union the resolver sees is
        // not empty and the "found nothing at all" guard never fires.
        #expect(apps.discoveredBundleFilenames == ["Host.app"])

        func sharedRootOffered(
            sweeping sweep: @escaping @Sendable () -> (filenames: Set<String>, fullyRead: Bool)
        ) async throws -> Bool {
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
                receiptsReadable: { true },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                appFilenamesOutsideScanRoots: sweep,
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // The one root outlasts its deadline, so nothing is known about what
        // sits outside the scan roots and `outside-vendor` cannot be proved
        // absent. The listing is supplied rather than timed out for real: see
        // `bundleFilenames(directlyUnder:within:reading:)`.
        #expect(try await sharedRootOffered(sweeping: {
            InstalledApps.bundleFilenames(
                directlyUnder: [elsewhere], within: 0.1,
                reading: { _ in
                    Thread.sleep(forTimeInterval: 5)
                    return []
                })
        }) == false)

        // Control, and the whole point of the fixture: a sweep that did
        // finish and genuinely found nothing outside the scan roots proves
        // `outside-vendor` absent and releases the shared root. The refusal
        // above is therefore the abandoned listing and not the fixture.
        #expect(try await sharedRootOffered(sweeping: {
            InstalledApps.bundleFilenames(directlyUnder: [])
        }) == true)

        // The other control: swept for real, the rival really is there.
        #expect(try await sharedRootOffered(sweeping: {
            InstalledApps.bundleFilenames(directlyUnder: [elsewhere])
        }) == false)
    }
}

/// A scan root the walk could not read must not prove a cask absent either.
///
/// The walk drops a subtree it cannot list and carries on, which is right, but
/// `discoveredBundleFilenames` then comes back short of every bundle under it
/// — and that set is half the union the presence resolver reads as "the
/// applications on this machine". The other half, the presence sweep, already
/// says when it is short; until the scan says so too, an unreadable
/// `/Applications` subtree releases the zap paths of every product inside it
/// while the sweep beside it reports the union complete.
///
/// Forced here with a scan root whose one subdirectory cannot be listed, while
/// the sweep is given nothing to do and so reads whole — the case an "is the
/// union empty?" test cannot see, since `Host.app` keeps it non-empty.
///
/// Guarded against passing vacuously by the control: the same fixture with the
/// subtree readable proves `outside-vendor` absent and releases the shared
/// root, so the refusal is the permissions and nothing else.
@Test func aScanRootThatCouldNotBeReadDoesNotProveACaskAbsent() async throws {
    guard getuid() != 0 else { return }  // root can list a 000 directory
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        let vendor = appsRoot.appendingPathComponent("Vendor", isDirectory: true)

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        try FileManager.default.createDirectory(
            at: vendor.appendingPathComponent("Other", isDirectory: true),
            withIntermediateDirectories: true)
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "outside-vendor", "artifacts": [
              { "app": ["Outside.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))
        let env = ScanEnvironment(libraryURL: library)

        func sharedRootOffered() async throws -> Bool {
            let apps = InstalledApps.scan(
                roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
                receiptsReadable: { true },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                // Nothing to sweep, so the sweep half of the union reads
                // whole and only the scan half can be short.
                appFilenamesOutsideScanRoots: { InstalledApps.bundleFilenames(directlyUnder: []) },
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // Control first, while the subtree is readable: the walk covers every
        // directory under the root, finds no `Outside.app`, and that is a
        // finding — `outside-vendor` is proved absent and the shared root is
        // released.
        #expect(try await sharedRootOffered() == true)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: vendor.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: vendor.path)
        }

        // Same tree, same cask, one directory that will not answer: the walk
        // can no longer say `Outside.app` is not there, so the shared root
        // stays refused.
        #expect(try await sharedRootOffered() == false)
    }
}

/// The same bundle, at the level where dropping its name does damage: a cask
/// whose `app` artifact names an installed bundle the walk could not confirm
/// the type of must not be proved absent, so the directory it shares stays
/// refused.
///
/// `/Applications/Safari.app` is the real shape — a relative symlink into the
/// cryptex volume, whose URL answers "not a directory" — and it is why this is
/// not a hypothetical: the walk sees the name and had been discarding it.
///
/// Guarded against passing vacuously by the control: the same fixture without
/// the bundle proves `outside-vendor` absent and releases the shared root.
@Test func aBundleWhoseTypeCannotBeConfirmedStillRefusesTheSharedRoot() async throws {
    guard getuid() != 0 else { return }  // root can traverse a 000 directory
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let link = appsRoot.appendingPathComponent("Outside.app", isDirectory: true)

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        try makeAppBundle(
            tree, at: "vault/Outside.app", bundleID: "com.example.outside", displayName: "Outside")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: vault.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: vault.path)
        }

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "outside-vendor", "artifacts": [
              { "app": ["Outside.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))
        let env = ScanEnvironment(libraryURL: library)

        func sharedRootOffered() async throws -> Bool {
            let apps = InstalledApps.scan(
                roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env, receipts: { (receipts: [], fullyRead: true) },
                receiptsReadable: { true },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                appFilenamesOutsideScanRoots: { InstalledApps.bundleFilenames(directlyUnder: []) },
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // Control first, with nothing named `Outside.app` under the root: the
        // walk read every directory it was given and found no such name, which
        // is a finding — the cask is proved absent and the shared root goes.
        #expect(try await sharedRootOffered() == true)

        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: vault.appendingPathComponent("Outside.app"))
        // The premise: the type read really cannot confirm this is a bundle.
        #expect((try? link.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true)

        // And now the name is there, so the cask cannot be proved absent and
        // the shared root stays refused.
        #expect(try await sharedRootOffered() == false)
    }
}

/// The same rule one level inside the database. A receipt directory that
/// opened can still be short — one plist in it that will not parse drops its
/// receipt with nothing in the returned array to show for it — and a
/// `pkgutil`-only cask whose pattern would have matched the dropped receipt
/// misses instead. That miss is what proves the rival absent, which releases
/// the shared directory the live product is still using.
///
/// `receiptsReadable` cannot answer this: the directory opened, so it is
/// `true` in both runs below. The fact that separates them travels beside the
/// receipts themselves, which is why the seam returns both.
///
/// This is the wiring, not the rule. `CaskPresence` is unit-tested for it
/// directly; what this pins is that the coordinator hands the flag over rather
/// than passing a constant — the whole fix is inert if it does, and every
/// other test in this suite supplies `fullyRead: true` and would not notice.
@Test func aShortReceiptDatabaseProvesNoPkgutilOnlyCaskAbsent() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Host.app", bundleID: "com.example.host", displayName: "Host")
        try tree.file("Library/Application Support/Shared/marker", byteCount: 4096)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixtureForCoordinator("""
        [
          { "token": "host", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "\(support.path)/Shared" } ] } ] },
          { "token": "pkg-only-rival", "artifacts": [
              { "zap": [
                  { "trash": "\(support.path)/Shared", "pkgutil": "com.example.pkgonly" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))
        #expect(caskIndex.receiptPatterns(forCaskToken: "pkg-only-rival") == ["com.example.pkgonly"])

        let env = ScanEnvironment(libraryURL: library)
        let apps = InstalledApps.scan(
            roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        func sharedRootOffered(receiptsFullyRead: Bool) async throws -> Bool {
            let report = await UninstallCoordinator().run(
                installedApps: { apps }, environment: env,
                // Read, and holding no matching id — the miss is real. What
                // varies is only whether the read is known to be complete.
                receipts: { (receipts: [], fullyRead: receiptsFullyRead) },
                receiptsReadable: { true },
                caskIndex: { caskIndex }, caskroomTokens: { [] },
                appFilenamesOutsideScanRoots: { ([], true) },
                applicationGroups: { _ in [] }, isRunning: { _ in false })
            let rows = report.rows.compactMap { row -> AppFootprint? in
                guard case .app(let footprint) = row else { return nil }
                return footprint
            }
            let host = try #require(rows.first { $0.identity.bundleID == "com.example.host" })
            return host.items.contains { $0.path.path.hasSuffix("Application Support/Shared") }
        }

        // Short: the pattern that missed may have missed a receipt the read
        // dropped, so nothing is proved and the refusal stands.
        #expect(try await sharedRootOffered(receiptsFullyRead: false) == false)

        // Control: the identical miss against a database read whole IS a
        // finding, so the refusal above comes from the shortness and not from
        // a fixture that could never release anything.
        #expect(try await sharedRootOffered(receiptsFullyRead: true) == true)
    }
}
