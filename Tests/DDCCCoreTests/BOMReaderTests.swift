import Testing
import Foundation
@testable import DDCCCore

/// `lsbom` ships on every Mac and is the format's reference reader, so it is
/// the oracle this parser is measured against — the same shape as
/// `RefusalSetTests`' brute-force comparison. Hand-written fixtures cannot
/// cover a reverse-engineered binary format; a real receipt can.
///
/// Measured: all 78 receipts on the development machine match
/// byte-for-byte, including Xcode's 158,717-path manifest — 426,953 paths in
/// 1.9 s. A prototype had matched 77 of them; the 78th turned out to be this
/// helper's fault rather than the parser's, which is why the splitting below is
/// spelled out.
private func lsbomPaths(_ url: URL) -> [String]? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/lsbom")
    p.arguments = ["-s", url.path(percentEncoded: false)]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    // Split on the newline *byte*, not on Characters. `String.split(separator:
    // "\n")` walks grapheme clusters, and "\r\n" is a single cluster — so a
    // manifest holding `Icon\r` (the classic custom-icon file, which really is
    // on disk under that name) would have that line silently glued to the next
    // one and the oracle would accuse a correct parser of being wrong.
    // Measured: this is exactly what happens on
    // com.corel.pkg.painter2023.bom, the one receipt on this machine with
    // carriage returns in its names.
    return data.split(separator: UInt8(ascii: "\n"))
        .map { String(decoding: $0, as: UTF8.self) }
}

@Test func bomReaderAgreesWithLsbomOnEveryReceiptOnThisMachine() throws {
    let dir = URL(fileURLWithPath: "/var/db/receipts")
    let boms = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
        ?? []).filter { $0.hasSuffix(".bom") }.map { dir.appending(path: $0) }

    // A machine with no receipts must SAY it compared nothing rather than pass
    // silently. This suite has shipped tests that could not fail.
    guard !boms.isEmpty else {
        Issue.record("no receipts on this machine — the differential compared nothing")
        return
    }

    var compared = 0
    for bom in boms {
        guard let truth = lsbomPaths(bom) else { continue }
        let mine = try #require(BOMReader.paths(at: bom), "failed to parse \(bom.lastPathComponent)")
        #expect(mine.sorted() == truth.sorted(), "mismatch in \(bom.lastPathComponent)")
        compared += 1
    }
    #expect(compared > 0, "lsbom produced no output for any receipt")
}

@Test func aTruncatedBomIsRejectedRatherThanPartiallyParsed() throws {
    try withTempDirectory { root in
        let file = root.appending(path: "truncated.bom", directoryHint: .notDirectory)
        try Data("BOMStore".utf8 + Data(count: 16)).write(to: file)
        #expect(BOMReader.paths(at: file) == nil)
    }
}

/// The truncation test above only reaches the header length check. This one
/// hands the parser a real receipt cut in half — a file whose magic and header
/// are intact and whose block table now runs off the end. "Reject, never
/// continue" has to hold there too: a partial manifest is the dangerous answer,
/// because a caller cannot tell it is partial.
@Test func aTruncatedRealReceiptIsRejectedRatherThanPartiallyParsed() throws {
    let whole = try appleDoubleFixtureBytes()
    try withTempDirectory { root in
        let file = root.appending(path: "half.bom", directoryHint: .notDirectory)
        try whole.prefix(whole.count / 2).write(to: file)
        #expect(BOMReader.paths(at: file) == nil)
    }
}

/// Proves the per-block bounds check bites rather than merely existing: the
/// same fixture, whole, with every block address in the table moved outside the
/// file. Nothing about the file's length or magic changed, so only the check on
/// each `(address, length)` pair can catch this — and it must, because these
/// addresses are `UInt32`s out of a file this process did not write.
@Test func blockAddressesOutsideTheFileAreRefused() throws {
    var bytes = try appleDoubleFixtureBytes()
    // Same layout the parser reads: indexOffset at byte 16, then a UInt32 count
    // followed by that many (address, length) pairs.
    let indexOffset = try #require(bigEndianUInt32(bytes, at: 16))
    let count = try #require(bigEndianUInt32(bytes, at: Int(indexOffset)))
    #expect(count > 1)
    for entry in 0..<Int(count) {
        let at = Int(indexOffset) + 4 + entry * 8
        bytes.replaceSubrange(at..<(at + 4), with: [0xF0, 0x00, 0x00, 0x00])
    }
    try withTempDirectory { root in
        let intact = root.appending(path: "intact.bom", directoryHint: .notDirectory)
        let broken = root.appending(path: "broken.bom", directoryHint: .notDirectory)
        try appleDoubleFixtureBytes().write(to: intact)
        try bytes.write(to: broken)
        // The unmodified copy parsing is what stops this test passing vacuously.
        #expect(BOMReader.paths(at: intact) != nil)
        #expect(BOMReader.paths(at: broken) == nil)
    }
}

private func appleDoubleFixtureBytes() throws -> Data {
    let fixture = Bundle.module.url(
        forResource: "appledouble", withExtension: "bom", subdirectory: "Fixtures")
    return try Data(contentsOf: try #require(fixture, "fixture missing"))
}

private func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return data[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
}

@Test func aFileWithoutTheMagicIsRejected() throws {
    try withTempDirectory { root in
        let file = root.appending(path: "notabom.bom", directoryHint: .notDirectory)
        try Data(count: 4096).write(to: file)
        #expect(BOMReader.paths(at: file) == nil)
    }
}

/// The case the differential caught that inspection would not: entry counts
/// matched exactly while two entries differed, `._Icon` against `Icon`.
/// Committed so the case survives off the machine that found it.
///
/// (The disagreement was ultimately the oracle mis-splitting `\r\n`, not a
/// name-extraction bug — but a parser that did mangle these names would be
/// caught by exactly this fixture, and nothing else on this machine carries
/// them.)
///
/// The names are the point. `Icon\r` — a literal carriage return in the
/// filename — is how macOS has always stored a folder's custom icon, and
/// `._Icon\r` is its AppleDouble sidecar. Both are real files that a footprint
/// must be able to name, and anything that trims, cleans or line-splits a name
/// produces a path that does not exist on disk. The receipt that exposed this,
/// `com.corel.pkg.painter2023.bom`, is the only one on the development machine
/// with carriage returns in it — and at 2 MB it is over this plan's fixture
/// budget, so a 36 KB stand-in was generated from the same names with the
/// system's own BOM writer:
///
///     mkbom <tree with "Corel Painter 2023/Icon\r" and "._Icon\r"> appledouble.bom
///
/// `mkbom` wrote these bytes, not a person, so this is still the real format
/// rather than a hand-assembled guess at it. The differential above remains the
/// check that covers installer-written receipts.
@Test func appleDoubleNamesSurviveParsing() throws {
    // `.copy("Fixtures")` preserves the directory, so the resource lives under
    // that subdirectory in the bundle rather than at its root.
    let fixture = Bundle.module.url(
        forResource: "appledouble", withExtension: "bom", subdirectory: "Fixtures")
    let url = try #require(fixture, "fixture missing")
    let paths = try #require(BOMReader.paths(at: url))
    #expect(paths.contains("./Corel Painter 2023/._Icon\r"))
    #expect(paths.contains("./Corel Painter 2023/Icon\r"))
    // A parser that dropped the AppleDouble prefix or the carriage return would
    // still return the right number of paths, so assert the wrong forms absent.
    #expect(!paths.contains("./Corel Painter 2023/Icon"))
    #expect(!paths.contains("./Corel Painter 2023/._Icon"))
}

/// Builds a structurally valid BOM in memory whose leaf entries **all point at
/// the same `BOMFile` block**. Nothing in the format requires those indices to
/// be distinct, so one name of `nameLength` bytes is what every entry decodes —
/// which is how a small file buys a large allocation: entry count is bounded by
/// distinct ids, but the bytes behind each entry were not bounded at all.
private func synthesizedBOM(nameLength: Int, entries: Int) -> Data {
    func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    func be16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    var content = Data()
    // Index 0 is the null block, exactly as a real receipt writes it.
    var blocks: [(address: UInt32, length: UInt32)] = [(0, 0)]
    func add(_ block: Data) -> UInt32 {
        let address = UInt32(32 + content.count)
        content.append(block)
        blocks.append((address, UInt32(block.count)))
        return UInt32(blocks.count - 1)
    }

    // One BOMFile — parent 0, then the name and its NUL — shared by every entry.
    let name = Data(repeating: UInt8(ascii: "n"), count: nameLength)
    let fileBlock = add(be32(0) + name + Data(count: 1))
    // One BOMPathInfo1 each, with distinct ids so the duplicate-id rejection
    // does not end the walk before the allocation happens.
    let infoBlocks = (0..<entries).map { add(be32(UInt32($0 + 1)) + be32(0)) }
    var leaf = be16(1) + be16(UInt16(entries)) + be32(0) + be32(0)
    for info in infoBlocks { leaf += be32(info) + be32(fileBlock) }
    let leafBlock = add(leaf)
    let treeBlock = add(
        Data("tree".utf8) + be32(1) + be32(leafBlock) + be32(4096) + be32(UInt32(entries)))

    var vars = be32(1) + be32(treeBlock)
    vars.append(UInt8(5))
    vars += Data("Paths".utf8)
    var index = be32(UInt32(blocks.count))
    for block in blocks { index += be32(block.address) + be32(block.length) }

    let varsOffset = UInt32(32 + content.count)
    let indexOffset = varsOffset + UInt32(vars.count)
    var file = Data("BOMStore".utf8) + be32(1) + be32(UInt32(blocks.count))
    file += be32(indexOffset) + be32(UInt32(index.count))
    file += be32(varsOffset) + be32(UInt32(vars.count))
    return file + content + vars + index
}

/// A name is bounded by `NAME_MAX`, not by its block.
///
/// Before that bound existed, a name could be as long as the whole file and
/// every entry could point at it, so peak allocation went as roughly N²/72 for
/// an N-byte input — the 133 KB file built here decoded to about 200 MB, and a
/// 1 MB one would have reached ~14 GB. The only reason it was not reachable is
/// that today's caller reads root-owned `/var/db/receipts`, and that is a
/// property of the caller rather than of this parser.
@Test func aNameLongerThanAPathComponentIsRefused() throws {
    try withTempDirectory { root in
        // The control matters: it proves this builder writes something the
        // parser accepts, so the rejection below is about the name's length and
        // not about scaffolding the parser dislikes for some other reason.
        let control = root.appending(path: "short.bom", directoryHint: .notDirectory)
        try synthesizedBOM(nameLength: 8, entries: 2000).write(to: control)
        let parsed = try #require(BOMReader.paths(at: control))
        #expect(parsed.count == 2000)
        #expect(parsed.first == String(repeating: "n", count: 8))

        let oversized = root.appending(path: "oversized.bom", directoryHint: .notDirectory)
        let bytes = synthesizedBOM(nameLength: 100_000, entries: 2000)
        #expect(bytes.count < 200_000, "the point is a small file, not a large one")
        try bytes.write(to: oversized)
        #expect(BOMReader.paths(at: oversized) == nil)
    }
}
