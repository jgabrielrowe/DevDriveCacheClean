import Testing
import Foundation
@testable import DDCCCore

/// `ReceiptStore` joins a `BOMReader` manifest to a receipt's install
/// prefix. The `appledouble.bom` fixture (shared with `BOMReaderTests`,
/// 18 entries) is reused here rather than a hand-built BOM: it already
/// exercises the root entry (`.`), nested entries several levels deep, and
/// names with a literal carriage return (`Icon\r`, `._Icon\r`) whose exact
/// bytes a join must preserve.
private func appleDoubleFixtureURL() throws -> URL {
    let fixture = Bundle.module.url(
        forResource: "appledouble", withExtension: "bom", subdirectory: "Fixtures")
    return try #require(fixture, "fixture missing")
}

// MARK: - paths(of:) — prefix joining

@Test func pathsOfJoinsBomEntriesUnderTheInstallPrefix() throws {
    let receipt = Receipt(
        packageID: "com.example.painter",
        installPrefix: "Applications",
        bomURL: try appleDoubleFixtureURL())
    let paths = try #require(ReceiptStore.paths(of: receipt))

    // The root "." entry joins to the prefix directory itself.
    #expect(paths.contains("/Applications"))
    #expect(paths.contains("/Applications/Corel Painter 2023"))
    // A nested entry, several components deep.
    #expect(paths.contains(
        "/Applications/Corel Painter 2023/Brushes/Painter 23 Brushes/._Acrylics"))
    // Exact bytes preserved, including the trailing carriage return.
    #expect(paths.contains("/Applications/Corel Painter 2023/._Icon\r"))
    #expect(paths.contains("/Applications/Corel Painter 2023/Icon\r"))
    #expect(paths.count == 18)

    // Never a bare BOM path or a "./"-prefixed one: every result is
    // absolute and already joined.
    for path in paths {
        #expect(path.hasPrefix("/"))
        #expect(!path.contains("./"))
    }
}

@Test func pathsOfTreatsAnAbsentInstallPrefixAsTheVolumeRoot() throws {
    let receipt = Receipt(
        packageID: "com.example.painter",
        installPrefix: "",
        bomURL: try appleDoubleFixtureURL())
    let paths = try #require(ReceiptStore.paths(of: receipt))

    #expect(paths.contains("/"))
    #expect(paths.contains("/Corel Painter 2023"))
    #expect(paths.contains("/Corel Painter 2023/._Icon\r"))
    #expect(paths.contains("/Corel Painter 2023/Icon\r"))
}

@Test func pathsOfTreatsALiteralSlashInstallPrefixAsTheVolumeRoot() throws {
    // Three receipts on the development machine (Apple's own Xcode,
    // GarageBand, and iMovie App Store packages) spell "the root" this way
    // instead of leaving the key out. Both spellings must join identically.
    let receipt = Receipt(
        packageID: "com.apple.pkg.example",
        installPrefix: "/",
        bomURL: try appleDoubleFixtureURL())
    let paths = try #require(ReceiptStore.paths(of: receipt))

    #expect(paths.contains("/"))
    #expect(paths.contains("/Corel Painter 2023"))
}

@Test func pathsOfNeverProducesADoubleSlashForARootPrefix() throws {
    let receipt = Receipt(
        packageID: "com.example.painter", installPrefix: "/", bomURL: try appleDoubleFixtureURL())
    let paths = try #require(ReceiptStore.paths(of: receipt))
    #expect(paths.allSatisfy { !$0.contains("//") })
}

@Test func pathsOfAcceptsAnInstallPrefixThatAlreadyHasALeadingSlash() throws {
    // Not observed on this machine — every non-root, non-empty
    // `InstallPrefixPath` among the 78 real receipts here omits the
    // leading slash — but `installPrefixURL(_:)` has a branch specifically
    // for a value that already has one (accept it rather than doubling
    // it), and nothing rules out a receipt elsewhere spelling it this way.
    // Without this test that branch is dead: the `prefix == "/"` case is
    // caught by the earlier `isEmpty || == "/"` shortcut, so only a
    // non-root already-absolute prefix like this one reaches it.
    let receipt = Receipt(
        packageID: "com.example.alreadyabsolute",
        installPrefix: "/usr/local/share/dotnet",
        bomURL: try appleDoubleFixtureURL())
    let paths = try #require(ReceiptStore.paths(of: receipt))
    #expect(paths.contains("/usr/local/share/dotnet"))
    #expect(paths.contains("/usr/local/share/dotnet/Corel Painter 2023"))
    #expect(paths.allSatisfy { !$0.contains("//") })
}

// MARK: - paths(of:) — missing BOM

@Test func pathsOfReturnsNilWhenTheReceiptHasNoBomURL() {
    let receipt = Receipt(packageID: "com.example.nomanifest", installPrefix: "Applications", bomURL: nil)
    #expect(ReceiptStore.paths(of: receipt) == nil)
}

@Test func pathsOfReturnsNilWhenTheBomURLDoesNotExistOnDisk() throws {
    try withTempDirectory { root in
        let ghost = root.appending(path: "gone.bom", directoryHint: .notDirectory)
        let receipt = Receipt(packageID: "com.example.ghost", installPrefix: "Applications", bomURL: ghost)
        #expect(ReceiptStore.paths(of: receipt) == nil)
    }
}

// MARK: - receipts(in:) — directory handling

@Test func receiptsInAnUnreadableDirectoryYieldsAnEmptyArray() throws {
    // A directory that was never created is the simplest unreadable case,
    // and is exactly what a sandbox denied access to `/var/db/receipts`
    // looks like from here: the listing call fails, not the app.
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DDCCTests-no-such-receipts-\(UUID().uuidString)", isDirectory: true)
    #expect(ReceiptStore.receipts(in: missing) == [])
}

@Test func receiptsInADirectoryWithNoPermissionYieldsAnEmptyArray() throws {
    try withTempDirectory { root in
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            // Restore before `withTempDirectory`'s cleanup tries to remove it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        #expect(ReceiptStore.receipts(in: locked) == [])
    }
}

// MARK: - receipts(in:) — reading plists

private func writeReceiptPlist(
    packageID: String?, installPrefix: String?, to url: URL
) throws {
    var plist: [String: Any] = [:]
    if let packageID { plist["PackageIdentifier"] = packageID }
    if let installPrefix { plist["InstallPrefixPath"] = installPrefix }
    plist["PackageVersion"] = "1.0"
    let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url)
}

@Test func receiptsInReadsThePackageIdentifierAndInstallPrefixAndFindsTheSiblingBom() throws {
    try withTempDirectory { root in
        let plistURL = root.appending(path: "com.example.painter.plist", directoryHint: .notDirectory)
        try writeReceiptPlist(packageID: "com.example.painter", installPrefix: "Applications", to: plistURL)
        let bomURL = root.appending(path: "com.example.painter.bom", directoryHint: .notDirectory)
        try Data(contentsOf: try appleDoubleFixtureURL()).write(to: bomURL)

        let receipts = ReceiptStore.receipts(in: root)
        let receipt = try #require(receipts.first { $0.packageID == "com.example.painter" })
        #expect(receipt.installPrefix == "Applications")
        // Compared after resolving symlinks: the temp root itself sits
        // behind a symlink (`/var` -> `/private/var`), and `receipts(in:)`
        // reads it back out through `FileManager.contentsOfDirectory`,
        // which resolves that hop independently of how this test built the
        // expected URL. The receipt's own basename-derived join is what is
        // under test, not which of the two equivalent spellings won.
        #expect(
            receipt.bomURL?.resolvingSymlinksInPath().path
                == bomURL.resolvingSymlinksInPath().path)
        #expect(receipts.count == 1)

        let paths = try #require(ReceiptStore.paths(of: receipt))
        #expect(paths.contains("/Applications/Corel Painter 2023"))
    }
}

@Test func receiptsInLeavesBomURLNilWhenNoSiblingBomExists() throws {
    try withTempDirectory { root in
        let plistURL = root.appending(path: "com.example.nomanifest.plist", directoryHint: .notDirectory)
        try writeReceiptPlist(packageID: "com.example.nomanifest", installPrefix: "", to: plistURL)

        let receipts = ReceiptStore.receipts(in: root)
        let receipt = try #require(receipts.first)
        #expect(receipt.bomURL == nil)
        #expect(ReceiptStore.paths(of: receipt) == nil)
    }
}

@Test func receiptsInSkipsAPlistMissingAPackageIdentifierButKeepsItsSiblings() throws {
    try withTempDirectory { root in
        let bad = root.appending(path: "com.example.broken.plist", directoryHint: .notDirectory)
        try writeReceiptPlist(packageID: nil, installPrefix: "Applications", to: bad)

        let good = root.appending(path: "com.example.good.plist", directoryHint: .notDirectory)
        try writeReceiptPlist(packageID: "com.example.good", installPrefix: "", to: good)

        let receipts = ReceiptStore.receipts(in: root)
        #expect(receipts.count == 1)
        #expect(receipts.first?.packageID == "com.example.good")
    }
}

@Test func receiptsInIgnoresNonPlistFiles() throws {
    try withTempDirectory { root in
        let good = root.appending(path: "com.example.good.plist", directoryHint: .notDirectory)
        try writeReceiptPlist(packageID: "com.example.good", installPrefix: "", to: good)
        try Data("not a receipt".utf8).write(
            to: root.appending(path: "README.txt", directoryHint: .notDirectory))

        let receipts = ReceiptStore.receipts(in: root)
        #expect(receipts.count == 1)
    }
}

// MARK: - Real receipts on this machine

/// Samples, rather than sweeps, the real receipts on the development
/// machine — a deliberate departure from `BOMReaderTests`' full 78-receipt
/// differential.
///
/// That differential already proves `BOMReader` itself agrees with `lsbom`
/// on every receipt; re-parsing all 78 here would pay that same
/// BOM-parsing cost again just to exercise the join on top of it, for
/// assertions that do not vary once a receipt's `InstallPrefixPath` shape
/// is known. Measured: exactly **three** shapes exist across
/// all 78 — absent/empty, the literal `"/"`, and a path with no leading
/// slash — and the synthetic tests above already cover all three, plus the
/// double-slash and root-`.` cases, and (via
/// `pathsOfAcceptsAnInstallPrefixThatAlreadyHasALeadingSlash`) a fourth
/// shape that does not exist here at all. A real-receipt sample's only
/// genuine addition on top of that is proving the join holds against real,
/// non-synthetic `BOMReader` output — which nothing else in this file
/// does. One receipt per shape observed, plus the largest BOM on the
/// machine (Xcode's, 38 MB / 158,717 paths per `BOMReader`'s own doc
/// comment) as a size stress case, buys that without looping all 78:
/// looping them cost this test alone 6.67s out of the suite's total 6.8s.
///
/// If a future receipt introduces a shape not in this set, add a case for
/// it explicitly — do not "restore completeness" by looping every receipt
/// again without re-reading this comment for what that costs.
@Test func realReceiptsOnThisMachineRoundTripThroughReceiptsAndPaths() throws {
    let dir = URL(fileURLWithPath: "/var/db/receipts")
    let receipts = ReceiptStore.receipts(in: dir)
    guard !receipts.isEmpty else {
        Issue.record("no receipts on this machine — nothing was sampled or verified")
        return
    }

    enum Shape: Hashable { case absentOrEmpty, literalSlash, noLeadingSlash }
    func shape(of receipt: Receipt) -> Shape {
        if receipt.installPrefix.isEmpty { return .absentOrEmpty }
        if receipt.installPrefix == "/" { return .literalSlash }
        return .noLeadingSlash
    }

    var byShape: [Shape: Receipt] = [:]
    for receipt in receipts where receipt.bomURL != nil {
        let key = shape(of: receipt)
        if byShape[key] == nil { byShape[key] = receipt }
    }

    let largestByBomSize = receipts
        .compactMap { receipt -> (Receipt, Int)? in
            guard let bomURL = receipt.bomURL,
                  let size = try? FileManager.default
                      .attributesOfItem(atPath: bomURL.path(percentEncoded: false))[.size] as? Int
            else { return nil }
            return (receipt, size)
        }
        .max { $0.1 < $1.1 }
        .map(\.0)

    var sample = Array(byShape.values)
    if let largestByBomSize, !sample.contains(where: { $0.packageID == largestByBomSize.packageID }) {
        sample.append(largestByBomSize)
    }

    guard !sample.isEmpty else {
        Issue.record("every receipt on this machine has bomURL == nil — nothing to sample")
        return
    }

    for receipt in sample {
        guard let paths = ReceiptStore.paths(of: receipt) else {
            Issue.record("paths(of:) returned nil for \(receipt.packageID as String), which has a bomURL")
            continue
        }
        #expect(
            paths.allSatisfy { $0.hasPrefix("/") },
            "non-absolute path from \(receipt.packageID as String)")
        #expect(
            paths.allSatisfy { !$0.contains("//") },
            "double slash from \(receipt.packageID as String)")
    }
}

// MARK: - Readable, or merely empty

/// `receipts(in:)` returns `[]` for a directory it read and found empty and
/// for one it could not open at all, and that collapse is deliberate for a
/// caller that only wants receipts. A caller deciding whether a receipt's
/// *absence* proves anything needs the two apart, so this is the probe that
/// separates them. Pinned in both directions: a false that never fires is
/// the same as not having the probe.
@Test func aReadableDirectoryIsEnumerableAndAMissingOneIsNot() throws {
    try withTempDirectory { dir in
        #expect(ReceiptStore.canEnumerate(dir))
        // Empty and readable is still readable — the whole point of the
        // distinction `receipts(in:)` collapses.
        #expect(ReceiptStore.receipts(in: dir).isEmpty)

        #expect(ReceiptStore.canEnumerate(dir.appending(path: "no-such-directory")) == false)
    }
}

/// The `false` branch on a directory that exists and cannot be listed —
/// the state that actually occurs on a machine running without Full Disk
/// Access, where `/var/db/receipts` is present and unreadable. `receipts(in:)`
/// reports the same empty array here as for a genuinely empty database.
@Test func aDirectoryThatCannotBeListedIsNotEnumerable() throws {
    // Root reads a mode-000 directory regardless of its bits, so under root
    // this would be asserting something about the test runner rather than
    // about the code. Skipped there instead of asserting a false answer.
    guard getuid() != 0 else { return }

    try withTempDirectory { dir in
        let sealed = dir.appending(path: "sealed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        defer {
            // Restored so the temp-directory cleanup can remove it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path)
        }

        #expect(ReceiptStore.canEnumerate(sealed) == false)
        // The collapse this probe exists to undo: indistinguishable from empty.
        #expect(ReceiptStore.receipts(in: sealed).isEmpty)
    }
}

// MARK: - read(in:) — a receipt that could not be read is not one that is absent

/// `receipts(in:)` drops a plist it cannot parse, which is right for a caller
/// looking for something and wrong for a caller reading a *miss* as proof.
/// `CaskPresence` does the latter: a cask whose `pkgutil` pattern matches no
/// receipt is proved absent, and its paths stop refusing. A database that
/// listed fine but held one unreadable receipt hands that caller a short set
/// wearing no mark of being short.
///
/// `canEnumerate` already separates "could not open the directory" from
/// "directory is empty". This is the same distinction one level down, inside a
/// directory that opened.
///
/// Zero occurrences on a measured machine — 78 plists under `/var/db/receipts`,
/// all of them parsing. The rule, not a reading of today's disk.
@Test func aReceiptThatCannotBeParsedLeavesTheReadShort() throws {
    try withTempDirectory { root in
        try writeReceiptPlist(
            packageID: "com.example.good", installPrefix: "Applications",
            to: root.appending(path: "com.example.good.plist", directoryHint: .notDirectory))
        try Data("not a plist".utf8).write(
            to: root.appending(path: "com.example.broken.plist", directoryHint: .notDirectory))

        let read = ReceiptStore.read(in: root)

        // The readable receipt still counts: one bad plist costs that receipt
        // and no other, exactly as before. Only the claim of completeness goes.
        #expect(read.receipts.map(\.packageID) == ["com.example.good"])
        #expect(!read.fullyRead)
    }
}

/// The control the one above needs: a database whose every receipt parsed
/// reports complete, so the flag is a finding rather than a constant.
@Test func aReceiptDatabaseThatParsedWholeReportsItself() throws {
    try withTempDirectory { root in
        try writeReceiptPlist(
            packageID: "com.example.one", installPrefix: "Applications",
            to: root.appending(path: "com.example.one.plist", directoryHint: .notDirectory))

        let read = ReceiptStore.read(in: root)
        #expect(read.receipts.count == 1)
        #expect(read.fullyRead)
    }
}

/// An empty database read whole is complete — nothing was there to miss. This
/// is the state a `pkgutil`-only cask is legitimately proved absent by, so
/// folding it in with the two failures above would disable that proof on every
/// machine with no receipts.
@Test func anEmptyReceiptDatabaseIsCompleteRatherThanShort() throws {
    try withTempDirectory { root in
        let read = ReceiptStore.read(in: root)
        #expect(read.receipts.isEmpty)
        #expect(read.fullyRead)
    }
}

/// A directory that would not open reads short as well as empty. The caller
/// separates the two facts with `canEnumerate`, but neither of them is a
/// database this read whole.
@Test func aReceiptDirectoryThatWillNotOpenIsNotAReadThatCompleted() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DDCCTests-no-receipts-\(UUID().uuidString)", isDirectory: true)
    let read = ReceiptStore.read(in: missing)
    #expect(read.receipts.isEmpty)
    #expect(!read.fullyRead)
}
