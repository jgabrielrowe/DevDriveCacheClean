import Testing
import Foundation
@testable import DDCCCore

// MARK: - Fixture helpers

/// Creates a minimal `.app` bundle that `InstalledApps.scan` can read an
/// identifier out of. Kept file-private and duplicated rather than shared,
/// matching every other test file in this suite's own choice.
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

/// Wraps a cask array as the JWS envelope `CaskIndex.load` expects — the
/// cask JSON lives inside `payload` as a *string*, not as nested JSON. Same
/// shape every other file's own fixture helper uses.
private func writeCaskFixture(_ casks: String, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: ["payload": casks, "signatures": []])
    try data.write(to: url)
}

// MARK: - Rule 1: never invent

/// The line this project already drew and must not cross back over: a
/// directory sitting under `~/Library` is not evidence of anything. Two
/// receipts and one cask are present in this fixture, all for *other*,
/// still-installed apps — proving recovery does not spuriously fire just
/// because receipts and casks exist somewhere in the input, only that a
/// bare, evidence-less directory produces nothing on its own.
@Test func anIdentityIsNeverInventedFromADirectoryNameAlone() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        // A real, live app — its receipt and cask both name it, so neither
        // mechanism should recover anything for it either.
        try makeAppBundle(
            tree, at: "Applications/Live.app", bundleID: "com.example.live", displayName: "Live")

        // The bare directory this rule exists to refuse: no receipt names
        // it, no cask names it, nothing but its own path.
        try tree.file("Library/Application Support/GhostApp/data", byteCount: 4096)

        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let liveReceipt = Receipt(packageID: "com.example.live", installPrefix: "/", bomURL: nil)

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "live-app", "artifacts": [ { "app": ["Live.app"] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let recovered = RecoveredIdentities.recover(
            installed: installed, receipts: [liveReceipt], caskIndex: caskIndex,
            caskroomTokens: ["live-app"], environment: env)

        #expect(recovered.isEmpty)
    }
}

// MARK: - Rule 2: never duplicate

/// The installed row is the better-evidenced one; recovery must not produce
/// a second row for an app that is right there on disk — checked against
/// both mechanisms in one fixture, each carrying one duplicate and one
/// genuinely novel entry, so an off-by-one or an accidental "keep both"
/// would actually be caught rather than agreeing with a trivial fixture by
/// coincidence.
@Test func aRecoveredIdentityNeverDuplicatesAnInstalledOne() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        try makeAppBundle(
            tree, at: "Applications/Installed.app", bundleID: "com.example.installed",
            displayName: "Installed")
        try makeAppBundle(
            tree, at: "Applications/Real.app", bundleID: "com.example.real", displayName: "Real")

        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        // Receipts: one duplicates an installed bundle id, one does not.
        let duplicateReceipt = Receipt(packageID: "com.example.installed", installPrefix: "/", bomURL: nil)
        let novelReceipt = Receipt(packageID: "com.example.ghost", installPrefix: "/", bomURL: nil)

        // Casks: one names an installed app's bundle filename, one does not.
        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "real-app", "artifacts": [ { "app": ["Real.app"] } ] },
          { "token": "ghost-app", "artifacts": [ { "app": ["Ghost.app"] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let recovered = RecoveredIdentities.recover(
            installed: installed, receipts: [duplicateReceipt, novelReceipt],
            caskIndex: caskIndex, caskroomTokens: ["real-app", "ghost-app"], environment: env)

        #expect(recovered.count == 2)
        #expect(Set(recovered.map(\.bundleID)) == ["com.example.ghost", "ghost-app"])
        #expect(recovered.allSatisfy { !$0.isPresent })

        // the rule: `namespace` records which mechanism actually
        // produced each id, machine-readably rather than in `displayName`.
        let ghostReceiptIdentity = try #require(
            recovered.first { $0.bundleID == "com.example.ghost" })
        #expect(ghostReceiptIdentity.namespace == .packageID)
        let ghostCaskIdentity = try #require(recovered.first { $0.bundleID == "ghost-app" })
        #expect(ghostCaskIdentity.namespace == .caskToken)
    }
}

// MARK: - the rule: the Caskroom anchor, not the cask catalog

/// `CaskIndex.load` parses Homebrew's API catalog of every cask it
/// *offers* — thousands of entries, most never installed on this machine.
/// A catalog entry alone is not evidence of an install; only a Caskroom
/// listing is. This fixture has two catalog entries and only one Caskroom
/// entry, so "recover every catalog app name" and "recover only the
/// Caskroom-listed one" disagree — the shape the dispatch's own coincidence
/// warning named, reproduced here for the one place it applied.
@Test func aCaskCatalogEntryWithNoCaskroomRecordIsNeverRecovered() throws {
    try withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "installed-app", "artifacts": [ { "app": ["Installed.app"] } ] },
          { "token": "catalog-only-app", "artifacts": [ { "app": ["CatalogOnly.app"] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        // Only one of the two casks actually has a Caskroom entry.
        let recovered = RecoveredIdentities.recover(
            installed: installed, receipts: [], caskIndex: caskIndex,
            caskroomTokens: ["installed-app"], environment: env)

        #expect(recovered.map(\.bundleID) == ["installed-app"])
    }
}

/// `nil` from the Caskroom probe (neither known prefix could be read) must
/// never fall back to reasoning over the catalog — it must recover zero
/// cask identities outright, even though the catalog above still declares
/// two app names.
@Test func aCaskroomThatCannotBeReadRecoversNoCaskIdentitiesAtAll() throws {
    try withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(roots: [], launchServices: { _ in false })

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "installed-app", "artifacts": [ { "app": ["Installed.app"] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let recovered = RecoveredIdentities.recover(
            installed: installed, receipts: [], caskIndex: caskIndex,
            caskroomTokens: nil, environment: env)

        #expect(recovered.isEmpty)
    }
}

/// `installedCaskTokens` itself: probes both given roots, unions whichever
/// are readable, and is `nil` only when *neither* is — never confused with
/// "readable and empty." Matches the real shape measured: one
/// prefix absent, the other present with entries.
@Test func installedCaskTokensUnionsBothRootsAndDistinguishesUnreadableFromEmpty() throws {
    try withTempDirectory { root in
        let present = root.appendingPathComponent("usr-local-caskroom", isDirectory: true)
        let absent = root.appendingPathComponent("opt-homebrew-caskroom", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: present.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: present.appendingPathComponent("gcloud-cli"), withIntermediateDirectories: true)

        let tokens = RecoveredIdentities.installedCaskTokens(roots: [absent, present])
        #expect(tokens == ["codex", "gcloud-cli"])

        let neitherReadable = RecoveredIdentities.installedCaskTokens(
            roots: [absent, root.appendingPathComponent("also-absent", isDirectory: true)])
        #expect(neitherReadable == nil)
    }
}

/// An installed bundle whose filename differs from the cask's declared
/// `app` only in case is the *same app*, and recovering it as an absent
/// identity is the unsafe direction of this type's own tie-break: a live
/// app's containers and preferences offered as leftovers, and its claim on
/// a shared group container stripped.
///
/// This pins `recoverFromCasks` to the same comparison
/// `CaskIndex.zapDeclarations(forAppBundleNamed:presence:)` uses, which its own
/// comment already claims it shares. The two drifting apart is invisible
/// from either side alone — the query half returns the right paths while
/// this half mints a phantom row for the app it just answered about.
@Test func anInstalledBundleIsNotRecoveredWhenOnlyItsFilenameCaseDiffers() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")

        // Installed as the mainline qBittorrent actually installs, lowercase.
        try makeAppBundle(
            tree, at: "Applications/qbittorrent.app",
            bundleID: "org.qbittorrent.qBittorrent", displayName: "qBittorrent")

        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        // The cask spells its artifact with the capital B, as the real
        // `c0re100-qbittorrent` cask does.
        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "c0re100-qbittorrent", "artifacts": [ { "app": ["qBittorrent.app"] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let recovered = RecoveredIdentities.recover(
            installed: installed, receipts: [],
            caskIndex: caskIndex, caskroomTokens: ["c0re100-qbittorrent"], environment: env)

        #expect(recovered.isEmpty)
    }
}

/// A cask with no `app` artifact cannot be reached by any app-shaped query,
/// so the Application Support knowledge it declares is unreachable however
/// good it is. Its `pkgutil` id is an install record of the same evidentiary
/// grade as a receipt, and anchors an identity the same way.
@Test func aCaskWithNoAppArtifactIsRecoveredFromItsMatchingReceipt() throws {
    try withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(
            at: appsRoot, withIntermediateDirectories: true)

        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(
            roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "microsoft-auto-update", "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.microsoft\\\\.package\\\\.Microsoft_AutoUpdate\\\\.app" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft AutoUpdate" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let receipt = Receipt(
            packageID: "com.microsoft.package.Microsoft_AutoUpdate.app",
            installPrefix: "/", bomURL: nil)

        let recovered = RecoveredIdentities.recover(
            installed: installed, receipts: [receipt],
            caskIndex: caskIndex, caskroomTokens: [], environment: env)

        let identity = try #require(recovered.first { $0.bundleID == "microsoft-auto-update" })
        #expect(identity.namespace == .caskReceipt)
        // A receipt match is evidence the product IS on this machine — the same
        // evidence `CaskPresence` reads to answer "present". Marking it absent
        // would describe a live pkg-installed product as leftovers, and would
        // make the two readers of one receipt disagree about it.
        #expect(identity.isPresent)
        // And no bundle: this arm exists precisely because the cask declares no
        // `app` artifact. A synthetic stand-in path would be a location the
        // assembler could offer for deletion; `nil` is the honest value, and
        // `FootprintAssembler.caskAnchor` reaches this identity by its token.
        #expect(identity.bundleURL == nil)
    }
}

/// The anchor is the receipt, not the catalogue. A cask whose `pkgutil` id
/// matches nothing on this machine is never recovered — the same bar
/// `recoverFromCasks` already sets by intersecting against the Caskroom
/// rather than reasoning over every token the catalogue mentions.
@Test func aCaskWhoseReceiptPatternMatchesNothingIsNeverRecovered() throws {
    try withTempDirectory { root in
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appsRoot = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(
            at: appsRoot, withIntermediateDirectories: true)

        let env = ScanEnvironment(libraryURL: library)
        let installed = InstalledApps.scan(
            roots: [appsRoot], maxDepth: 4, launchServices: { _ in false })

        let caskURL = root.appendingPathComponent("cask.jws.json")
        try writeCaskFixture("""
        [
          { "token": "never-installed", "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.absent" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Absent" } ] } ] }
        ]
        """, to: caskURL)
        let caskIndex = try #require(CaskIndex.load(from: caskURL))

        let recovered = RecoveredIdentities.recover(
            installed: installed,
            receipts: [Receipt(packageID: "com.example.other", installPrefix: "/", bomURL: nil)],
            caskIndex: caskIndex, caskroomTokens: [], environment: env)

        #expect(recovered.allSatisfy { $0.bundleID != "never-installed" })
    }
}
