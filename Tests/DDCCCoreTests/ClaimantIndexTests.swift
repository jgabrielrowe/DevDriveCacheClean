import Testing
import Foundation
@testable import DDCCCore

/// The rule: a shared resource is retained while any other
/// installed app still uses it, its bytes are excluded from the headline
/// figure until then, and the last app to go collects it.
///
/// Correctness rests on the claimant set being ENUMERABLE. For group
/// containers it exactly is — claimants are the installed apps whose
/// application-groups entitlement lists the group, which is the OS's own
/// access grant rather than a naming convention. Measured: all
/// three Affinity apps declare 6LVTQB9699.com.seriflabs and a sweep of
/// /Applications finds no others.

private func makeAppBundle(at url: URL, bundleID: String) throws {
    let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleName": url.deletingPathExtension().lastPathComponent,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appending(path: "Info.plist", directoryHint: .notDirectory))
}

/// Shared with `ReceiptStoreTests`/`BOMReaderTests`: 18 entries, including a
/// root `.` entry, reused here rather than hand-building a BOM (the format
/// is binary and not practical to fixture by hand).
private func appleDoubleFixtureURL() throws -> URL {
    let fixture = Bundle.module.url(
        forResource: "appledouble", withExtension: "bom", subdirectory: "Fixtures")
    return try #require(fixture, "fixture missing")
}

private let seriflabs = "6LVTQB9699.com.seriflabs"
private let seriflabsBeta = "6LVTQB9699.com.seriflabs.beta"

// MARK: - Discovery

/// `applicationGroups` returns a set, not a first match — a reader that
/// returned one element is the bug that produced this plan's original wrong
/// expected value for the Affinity case. Both declared groups exist here, so
/// collapsing to `.first` would non-deterministically drop one.
@Test func discoveryEmitsEveryDeclaredGroupContainerThatExists() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let containerA = try tree.directory("Library/Group Containers/\(seriflabs)")
        let containerB = try tree.directory("Library/Group Containers/\(seriflabsBeta)")
        let env = ScanEnvironment(libraryURL: library)

        let identity = BundleIdentity(
            bundleID: "com.seriflabs.designer", displayName: "Designer",
            bundleURL: root.appending(path: "Designer.app", directoryHint: .isDirectory), isPresent: true)

        let items = ClaimantIndex.discoverGroupContainerEvidence(
            for: identity, in: env, applicationGroups: { _ in [seriflabs, seriflabsBeta] })

        #expect(items.count == 2)
        let paths = Set(items.map(\.path))
        #expect(paths == [Candidate.normalizedPathKey(for: containerA), Candidate.normalizedPathKey(for: containerB)])
        #expect(items.allSatisfy { $0.source == .groupContainer && $0.claimedBy == "com.seriflabs.designer" })
    }
}

/// The measured Affinity shape: each app declares two groups and only the
/// first ever materializes a directory. Discovery emits evidence only for
/// what actually exists on disk — an `EvidenceItem` describes something
/// real, so the never-created `.beta` variant must not appear.
@Test func discoverySkipsADeclaredGroupWithNoContainerDirectory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let container = try tree.directory("Library/Group Containers/\(seriflabs)")
        // seriflabsBeta is declared below but never created on disk.
        let env = ScanEnvironment(libraryURL: library)

        let identity = BundleIdentity(
            bundleID: "com.seriflabs.photo", displayName: "Photo",
            bundleURL: root.appending(path: "Photo.app", directoryHint: .isDirectory), isPresent: true)

        let items = ClaimantIndex.discoverGroupContainerEvidence(
            for: identity, in: env, applicationGroups: { _ in [seriflabs, seriflabsBeta] })

        #expect(items.count == 1)
        #expect(items.first?.path == Candidate.normalizedPathKey(for: container))
    }
}

// MARK: - Counting

@Test func aGroupContainerIsRetainedWhileAnotherClaimantRemains() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let designerURL = root.appending(path: "Designer.app", directoryHint: .isDirectory)
        let photoURL = root.appending(path: "Photo.app", directoryHint: .isDirectory)
        try makeAppBundle(at: designerURL, bundleID: "com.seriflabs.designer")
        try makeAppBundle(at: photoURL, bundleID: "com.seriflabs.photo")
        try tree.directory("Library/Group Containers/\(seriflabs)")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { url in
                url.standardizedFileURL == designerURL.standardizedFileURL
                    || url.standardizedFileURL == photoURL.standardizedFileURL ? [seriflabs] : []
            })

        let sharedPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(seriflabs, isDirectory: true))

        #expect(index.claim(for: sharedPath)?.claimants == ["com.seriflabs.designer", "com.seriflabs.photo"])
        #expect(index.remainingClaimants(of: sharedPath, afterRemoving: "com.seriflabs.designer")
            == ["com.seriflabs.photo"])
    }
}

/// A claimant that cannot be read is not a claimant that is absent.
///
/// `applicationGroups` answers `nil` for a bundle whose code signature could
/// not be read at all — an unsigned bundle, one this process cannot open, one
/// that vanished between the scan and here. Reading that as "declares no
/// groups" removes a rival's claim on a shared container, and a container
/// whose only other claimant has been removed from the count is released:
/// Photo's half of the 1.76 GB Affinity container deleted while Photo is
/// still installed and still using it.
///
/// So one unreadable bundle downgrades every group-container claim in the
/// build to non-enumerable, exactly as one unparsed receipt downgrades every
/// receipt-derived claim. All-or-nothing for the same reason: there is no way
/// to tell which groups the bundle that could not be read would have declared.
@Test func aGroupContainerIsRetainedWhenAClaimantsEntitlementsCannotBeRead() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let designerURL = root.appending(path: "Designer.app", directoryHint: .isDirectory)
        let photoURL = root.appending(path: "Photo.app", directoryHint: .isDirectory)
        try makeAppBundle(at: designerURL, bundleID: "com.seriflabs.designer")
        try makeAppBundle(at: photoURL, bundleID: "com.seriflabs.photo")
        try tree.directory("Library/Group Containers/\(seriflabs)")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { url in
                // Designer's grant is read. Photo's signature is not.
                url.standardizedFileURL == designerURL.standardizedFileURL ? [seriflabs] : nil
            })

        let sharedPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(seriflabs, isDirectory: true))

        #expect(!index.remainingClaimants(of: sharedPath, afterRemoving: "com.seriflabs.designer").isEmpty)
    }
}

/// The control, and the reason the downgrade is keyed on an unreadable
/// signature rather than on an empty one. A bundle whose signature was read
/// and declares no groups is a finding, so a container only one app claims is
/// still released when that app goes — the rule above must not quietly retain
/// every group container on every machine.
@Test func aGroupContainerIsStillReleasedWhenEveryEntitlementWasRead() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let designerURL = root.appending(path: "Designer.app", directoryHint: .isDirectory)
        let photoURL = root.appending(path: "Photo.app", directoryHint: .isDirectory)
        try makeAppBundle(at: designerURL, bundleID: "com.seriflabs.designer")
        try makeAppBundle(at: photoURL, bundleID: "com.seriflabs.photo")
        try tree.directory("Library/Group Containers/\(seriflabs)")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { url in
                url.standardizedFileURL == designerURL.standardizedFileURL ? [seriflabs] : []
            })

        let sharedPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(seriflabs, isDirectory: true))

        #expect(index.remainingClaimants(of: sharedPath, afterRemoving: "com.seriflabs.designer").isEmpty)
    }
}

/// Distinguishes an entitlement-based claim from a name-based one, which the
/// Affinity fixtures above do not: `6LVTQB9699.com.seriflabs` team-strips to
/// `com.seriflabs`, a genuine dotted ancestor of `com.seriflabs.designer` —
/// so a naming-convention rule (e.g. dotted ascent on the stripped name)
/// would happen to match that specific case too, coincidentally. Measured
/// directly: mutating this file to derive claimants
/// by walking `Group Containers` and dotted-ascending the stripped name,
/// instead of reading the entitlement, leaves the tests above green. This
/// test uses a group directory name that bears no textual relationship at
/// all to the claiming apps' bundle ids — only the entitlement (here, the
/// injected `applicationGroups` closure) can possibly connect them — so a
/// name-based rule of any shape has nothing to match and must fail here.
@Test func aGroupContainerUnrelatedByNameToItsClaimantsIsStillCountedViaEntitlement() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let designerURL = root.appending(path: "Designer.app", directoryHint: .isDirectory)
        let photoURL = root.appending(path: "Photo.app", directoryHint: .isDirectory)
        try makeAppBundle(at: designerURL, bundleID: "com.seriflabs.designer")
        try makeAppBundle(at: photoURL, bundleID: "com.seriflabs.photo")
        let unrelatedGroup = "6LVTQB9699.zzz-nothing-like-either-bundle-id"
        try tree.directory("Library/Group Containers/\(unrelatedGroup)")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { url in
                url.standardizedFileURL == designerURL.standardizedFileURL
                    || url.standardizedFileURL == photoURL.standardizedFileURL ? [unrelatedGroup] : []
            })

        let sharedPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(unrelatedGroup, isDirectory: true))

        #expect(index.claim(for: sharedPath)?.claimants == ["com.seriflabs.designer", "com.seriflabs.photo"])
    }
}

@Test func aGroupContainerGoesToTheLastClaimantToBeRemoved() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let photoURL = root.appending(path: "Photo.app", directoryHint: .isDirectory)
        // Only Photo remains installed — Designer and Publisher are already gone.
        try makeAppBundle(at: photoURL, bundleID: "com.seriflabs.photo")
        try tree.directory("Library/Group Containers/\(seriflabs)")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { $0.standardizedFileURL == photoURL.standardizedFileURL ? [seriflabs] : [] })

        let sharedPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(seriflabs, isDirectory: true))

        #expect(index.remainingClaimants(of: sharedPath, afterRemoving: "com.seriflabs.photo").isEmpty)
    }
}

/// `ClaimantIndex` computes no totals and excludes no bytes itself. A caller
/// does that, once it reads `Claim.claimants.count > 1` as its signal to keep
/// a shared path out of a removal's headline figure. What this test
/// actually pins is the multiplicity that signal depends on: while two
/// installed apps both still claim a group container, before either has
/// been removed, the single `Claim` for that path lists both of them and
/// says the mechanism is closed.
@Test func aGroupContainerWithTwoInstalledClaimantsListsBothBeforeEitherIsRemoved() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let designerURL = root.appending(path: "Designer.app", directoryHint: .isDirectory)
        let photoURL = root.appending(path: "Photo.app", directoryHint: .isDirectory)
        try makeAppBundle(at: designerURL, bundleID: "com.seriflabs.designer")
        try makeAppBundle(at: photoURL, bundleID: "com.seriflabs.photo")
        try tree.directory("Library/Group Containers/\(seriflabs)")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { url in
                url.standardizedFileURL == designerURL.standardizedFileURL
                    || url.standardizedFileURL == photoURL.standardizedFileURL ? [seriflabs] : []
            })

        let sharedPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(seriflabs, isDirectory: true))

        let claim = index.claim(for: sharedPath)
        #expect(claim?.isEnumerable == true)
        #expect(claim?.population == .scannedInstalledApps)
        #expect(claim?.claimants.count == 2)
    }
}

/// An app can declare a group with no container directory on disk (measured:
/// every Affinity app declares the never-materialized `.beta` variant).
/// Claimant COUNTING must still record that app as a claimant of whatever
/// path the declaration maps to — dropping it would make a shared container
/// look like it has one fewer claimant than it really does, which is the
/// dangerous direction. Discovery (tested above) is what filters to what
/// exists; counting must not repeat that filter.
@Test func claimantCountingToleratesAClaimOnANonexistentGroupContainer() throws {
    try withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let designerURL = root.appending(path: "Designer.app", directoryHint: .isDirectory)
        try makeAppBundle(at: designerURL, bundleID: "com.seriflabs.designer")
        // Neither Group Containers directory is created on disk at all.

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        let env = ScanEnvironment(libraryURL: library)
        let index = ClaimantIndex.build(
            installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [],
            applicationGroups: { $0.standardizedFileURL == designerURL.standardizedFileURL
                ? [seriflabsBeta] : [] })

        let betaPath = Candidate.normalizedPathKey(
            for: env.groupContainersURL.appendingPathComponent(seriflabsBeta, isDirectory: true))

        #expect(index.claim(for: betaPath)?.claimants.contains("com.seriflabs.designer") == true)
    }
}

/// Enumerability is the whole safety argument. Word and Excel use
/// Application Support/Microsoft and declare it nowhere readable, so a
/// cask-declared vendor root can never be reference-counted — it is
/// narrowed instead, per CaskIndex. This pins that such a path is marked
/// non-enumerable and never becomes a removal target by exhaustion: removing
/// every app the caller happens to know about must never empty out its
/// claimant set.
@Test func aNonEnumerableSharedPathIsNeverClaimedByExhaustion() throws {
    let library = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Library", isDirectory: true)
    let env = ScanEnvironment(libraryURL: library)
    let vendorPath = Candidate.normalizedPathKey(
        for: library.appendingPathComponent("Application Support/Microsoft", isDirectory: true))

    let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })
    let index = ClaimantIndex.build(
        installedApps: apps, environment: env, receipts: [], nonEnumerableSharedPaths: [vendorPath])

    let claim = index.claim(for: vendorPath)
    #expect(claim?.isEnumerable == false)
    #expect(claim?.population == .unresolvable)

    // "Exhaustion" would be: ask about every app you know of, subtract each
    // one, and read the resulting emptiness as "nobody else claims this."
    #expect(!index.remainingClaimants(of: vendorPath, afterRemoving: "com.microsoft.Word").isEmpty)
    #expect(!index.remainingClaimants(of: vendorPath, afterRemoving: "com.microsoft.Excel").isEmpty)
}

/// A receipt this build could not parse (`ReceiptStore.paths(of:)` returned
/// `nil` — that type's own doc: unreadable never means "installed nothing")
/// might have declared any path at all, including one a sibling, readable
/// receipt in the same `build(...)` call also declares. There is no way to
/// know which already-known paths the refused receipt would have touched, so
/// the only sound response is to downgrade every receipt-derived claim in
/// that build — not just the refused receipt's own unknowable paths. Pinned
/// here: the readable receipt's own declared path still shows its claimant,
/// but `isEnumerable` flips to `false` once a sibling receipt refuses.
@Test func aRefusedReceiptDowngradesEveryReceiptDerivedClaimInTheSameBuild() throws {
    let refused = Receipt(packageID: "com.example.refused", installPrefix: "Applications", bomURL: nil)
    let readable = Receipt(
        packageID: "com.example.readable", installPrefix: "Applications", bomURL: try appleDoubleFixtureURL())

    let apps = InstalledApps.scan(roots: [], launchServices: { _ in false })
    let library = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Library", isDirectory: true)
    let env = ScanEnvironment(libraryURL: library)
    let index = ClaimantIndex.build(
        installedApps: apps, environment: env, receipts: [refused, readable], nonEnumerableSharedPaths: [])

    // The fixture's root "." entry joins straight to the install prefix.
    let readablePath = Candidate.normalizedPathKey(for: URL(fileURLWithPath: "/Applications"))
    let claim = index.claim(for: readablePath)

    #expect(claim?.isEnumerable == false)
    #expect(claim?.population == .unresolvable)
    #expect(claim?.claimants.contains("com.example.readable") == true)
    #expect(!index.remainingClaimants(of: readablePath, afterRemoving: "com.example.readable").isEmpty)
}
