import Testing
import Foundation
@testable import DDCCCore

/// Also the guard on `attr_length` semantics: `decodedName` now trusts
/// `attr_length` (minus the trailing NUL) as the name's exact byte count, so
/// a kernel that padded it would decode trailing NULs as valid U+0000 and
/// produce a wrong name rather than a counted hole — this exact-set
/// comparison against `FileManager` would catch that padding on APFS.
@Test func bulkReaderAgreesWithFileManagerOnNames() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("alpha.bin", byteCount: 100)
        try tree.file("beta.bin", byteCount: 200)
        try tree.directory("gamma")

        let bulk = Set(BulkDirectoryReader.entries(of: root).entries.map(\.name))
        let expected = Set(
            try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        )
        #expect(bulk == expected)
    }
}

@Test func bulkReaderIdentifiesDirectories() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("a-file.bin", byteCount: 10)
        try tree.directory("a-directory")

        let entries = BulkDirectoryReader.entries(of: root).entries
        let directory = try #require(entries.first { $0.name == "a-directory" })
        let file = try #require(entries.first { $0.name == "a-file.bin" })
        #expect(directory.isDirectory)
        #expect(file.isDirectory == false)
    }
}

@Test func bulkReaderReportsAModificationDateCloseToNow() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("fresh.bin", byteCount: 10)

        let entries = BulkDirectoryReader.entries(of: root).entries
        let file = try #require(entries.first { $0.name == "fresh.bin" })
        let modified = try #require(file.modified)
        #expect(abs(modified.timeIntervalSinceNow) < 60)
    }
}

/// A directory that cannot even be opened must be distinguishable from one
/// that is genuinely empty: a caller trusting `entries.isEmpty` alone would
/// silently report zero files for a directory it never actually read.
@Test func bulkReaderReturnsEmptyForAMissingDirectory() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let listing = BulkDirectoryReader.entries(of: missing)
    #expect(listing.entries.isEmpty)
    #expect(listing.readFailed)
}

/// One getattrlistbulk call returns a bounded batch, so a directory larger
/// than one batch exercises the loop that asks again. A reader that ignored
/// the continuation would silently report only the first slice — the
/// dangerous direction, because it hides files.
@Test func bulkReaderReadsPastASingleBatch() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<3_000 {
            try tree.file("entry-\(index).bin", byteCount: 1)
        }
        #expect(BulkDirectoryReader.entries(of: root).entries.count == 3_000)
    }
}

/// Measured on this machine, a 256 KB buffer holds this fixture's 3,000
/// entries in a single `getattrlistbulk` call, so `bulkReaderReadsPastASingleBatch`
/// alone does not force a second call — a reader that invoked the syscall
/// exactly once would still pass it at full count. A 4 KB buffer cannot hold
/// 3,000 entries, so this test forces the continuation loop deterministically
/// rather than depending on a fixture large enough to overflow the default.
@Test func bulkReaderReadsPastASingleBatchWithASmallBuffer() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<3_000 {
            try tree.file("entry-\(index).bin", byteCount: 1)
        }
        let listing = BulkDirectoryReader.entries(of: root, bufferBytes: 4_096)
        #expect(listing.entries.count == 3_000)
        #expect(listing.readFailed == false)
    }
}

/// Sizes are allocated size, matching what SizeCalculator reports, so a
/// number means the same thing in the Files view as in the Caches view.
///
/// The parse must stay aligned once ATTR_CMN_ERROR is requested — a shifted
/// cursor yields garbage names and absurd sizes rather than a crash.
///
/// Deliberately an exact-range size check rather than a lower bound: a
/// misaligned read returning a huge garbage value passes a `>=` test.
///
/// What this does NOT pin: moving the error block into bit order, after
/// MODTIME, leaves this test passing. Measured: — the kernel omits
/// the error bit for successful entries (`commonattr` 0x80000409), so the
/// guarded read is skipped and position cannot matter on a fixture where every
/// entry succeeds. Only an entry the kernel errors on would misparse, and no
/// fixture can produce one. The ungated form (`if true` in place of the bit
/// check) does fail this test, which is what shows the assertions themselves
/// are strong enough to catch a real shift.
@Test func requestingTheErrorAttributeDoesNotShiftTheOtherFields() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("aligned.bin", byteCount: 100_000)
        try tree.directory("child")

        let listing = BulkDirectoryReader.entries(of: root)

        let file = try #require(listing.entries.first { $0.name == "aligned.bin" })
        #expect(file.isDirectory == false)
        // Allocated size rounds up to a block multiple, so an exact equality
        // would be filesystem-dependent. One block of slack is tight enough to
        // catch a misparse and loose enough to survive a different block size.
        #expect(file.sizeBytes >= 100_000)
        #expect(file.sizeBytes < 100_000 + 65_536)
        #expect(try #require(file.modified).timeIntervalSinceNow > -60)

        let directory = try #require(listing.entries.first { $0.name == "child" })
        #expect(directory.isDirectory)

        #expect(listing.failedEntryCount == 0)
        #expect(listing.readFailed == false)
    }
}

/// The bytes a filesystem hands back are not guaranteed to be UTF-8, and the
/// two obvious conversions both fail badly: `String(cString:)` repairs them
/// into a plausible name that addresses nothing, and
/// `string(withFileSystemRepresentation:length:)` returns "", which resolves
/// back to the parent directory. Both measured: .
@Test func nameBytesThatAreNotUTF8DecodeToNothingRatherThanToSomethingWrong() {
    let invalid: [UInt8] = Array("bad".utf8) + [0xFF] + Array("name".utf8)
    invalid.withUnsafeBytes { raw in
        #expect(BulkDirectoryReader.decodedName(bytes: raw.baseAddress!, count: raw.count) == nil)
    }

    let truncated: [UInt8] = Array("x".utf8) + [0xE2, 0x82]
    truncated.withUnsafeBytes { raw in
        #expect(BulkDirectoryReader.decodedName(bytes: raw.baseAddress!, count: raw.count) == nil)
    }
}

/// The strict decoder must not reject the names that are actually out there.
@Test func ordinaryAndMultiByteNamesStillDecode() {
    let ascii: [UInt8] = Array("DerivedData".utf8)
    ascii.withUnsafeBytes { raw in
        #expect(BulkDirectoryReader.decodedName(bytes: raw.baseAddress!, count: raw.count) == "DerivedData")
    }

    let multiByte: [UInt8] = Array("caché ✅.bin".utf8)
    multiByte.withUnsafeBytes { raw in
        #expect(BulkDirectoryReader.decodedName(bytes: raw.baseAddress!, count: raw.count) == "caché ✅.bin")
    }

    // A zero-length name is not an undecodable one; it stays `.ignored`.
    let empty: [UInt8] = []
    empty.withUnsafeBytes { raw in
        #expect(BulkDirectoryReader.decodedName(bytes: raw.baseAddress?.advanced(by: 0) ?? UnsafeRawPointer(bitPattern: 0x1)!, count: 0) == nil)
    }
}
