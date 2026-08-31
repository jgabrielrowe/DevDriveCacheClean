// Sources/DDCCCore/Scanner/BulkDirectoryReader.swift
import Foundation
import Darwin

/// One directory entry, with the attributes the finder needs.
public struct BulkEntry: Sendable, Equatable {
    public let name: String
    public let isDirectory: Bool
    /// Allocated size, matching what `SizeCalculator` reports, so a number
    /// means the same thing in both views. Zero for directories.
    public let sizeBytes: Int64
    public let modified: Date?
}

/// The result of listing one directory.
public struct BulkDirectoryListing: Sendable {
    public let entries: [BulkEntry]
    /// True when the syscall reported an error. `entries` may then be a
    /// prefix of the directory rather than all of it, so a caller must
    /// treat any total derived from it as a floor.
    public let readFailed: Bool
    /// Entries the kernel could not return attributes for. Distinct from
    /// `readFailed`, which is a whole-directory failure: these are individual
    /// children that exist and are missing from `entries`. Without
    /// `ATTR_CMN_ERROR` requested there is no way to tell them apart from
    /// entries that were returned normally, so they were not counted.
    public let failedEntryCount: Int

    public init(entries: [BulkEntry], readFailed: Bool, failedEntryCount: Int) {
        self.entries = entries
        self.readFailed = readFailed
        self.failedEntryCount = failedEntryCount
    }
}

/// Lists a directory's children using `getattrlistbulk(2)`.
///
/// `FileManager` plus `URLResourceValues` costs a syscall per file per
/// attribute. Measured: home holds 2,073,009 files and 655,395
/// survive the finder's skip list — enough that per-file attribute fetching
/// is the difference between seconds and minutes, and a finder that takes
/// minutes will not be run. `getattrlistbulk` returns name, type, size and
/// modification date for a whole batch in one call.
public enum BulkDirectoryReader {

    /// 256 KB holds a few thousand entries per call in production. The loop
    /// below asks again until the kernel reports zero, so this is a
    /// throughput knob and never a cap on how many entries are returned.
    ///
    /// Measured on this machine: a 256 KB buffer holds up to ~3,276 entries
    /// of this fixture's shape before the kernel splits across a second
    /// call, so a fixture has to be that large (or larger) to force the
    /// continuation loop through the public entry point alone. The internal
    /// `entries(of:bufferBytes:)` overload below exists so a test can force
    /// the split deterministically with a small buffer instead of relying on
    /// a fixture big enough to overflow this default.
    private static let defaultBufferBytes = 256 * 1024

    public static func entries(of directory: URL) -> BulkDirectoryListing {
        read(of: directory, bufferBytes: defaultBufferBytes)
    }

    /// Test-only: forces a specific buffer size so the batch-continuation
    /// loop can be exercised deterministically. Deliberately not public —
    /// it exists for the test, not for callers.
    static func entries(of directory: URL, bufferBytes: Int) -> BulkDirectoryListing {
        read(of: directory, bufferBytes: bufferBytes)
    }

    private static func read(of directory: URL, bufferBytes: Int) -> BulkDirectoryListing {
        let descriptor = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            return BulkDirectoryListing(entries: [], readFailed: true, failedEntryCount: 0)
        }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        var entries: [BulkEntry] = []
        var buffer = [UInt8](repeating: 0, count: bufferBytes)
        var readFailed = false
        var failedEntryCount = 0

        while true {
            // `getattrlistbulk` returns Int32; the buffer-mutation closure
            // and the pointer-hoisted request are separated (rather than
            // nested as in the original sketch) because passing `&request`
            // inout while also holding an open `withUnsafeMutableBytes`
            // closure over `buffer` trips Swift 6's exclusivity checking.
            let returned: Int32 = withUnsafeMutablePointer(to: &request) { requestPointer in
                buffer.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return 0 }
                    return getattrlistbulk(descriptor, requestPointer, base, bufferBytes, 0)
                }
            }
            // 0 means the directory is exhausted — a clean, complete read.
            // Negative means an error (ENOTSUP on some SMB/NFS/FUSE mounts,
            // EINTR, or a failure partway through a large directory); the
            // caller must consult `readFailed` rather than trust `entries`
            // to be the whole directory, because on this branch it may only
            // be a prefix.
            if returned == 0 { break }
            if returned < 0 {
                readFailed = true
                break
            }

            buffer.withUnsafeBytes { raw in
                guard var cursor = raw.baseAddress else { return }
                for _ in 0..<Int(returned) {
                    let length = cursor.loadUnaligned(as: UInt32.self)
                    switch parse(cursor) {
                    case .entry(let entry): entries.append(entry)
                    case .failed: failedEntryCount += 1
                    case .ignored: break
                    }
                    cursor = cursor.advanced(by: Int(length))
                }
            }
        }
        return BulkDirectoryListing(
            entries: entries, readFailed: readFailed, failedEntryCount: failedEntryCount)
    }

    enum ParsedEntry {
        case entry(BulkEntry)
        /// The kernel reported an error for this directory entry, or its name
        /// is not valid UTF-8, or the kernel did not return a name at all —
        /// three ways this listing cannot address an entry that exists.
        case failed
        /// `.` or `..`. Nothing else lands here: an entry that exists but
        /// cannot be named is `.failed`, not silently dropped.
        case ignored
    }

    /// Strict UTF-8: `nil` rather than a repaired approximation.
    ///
    /// `String(cString:)` turns invalid bytes into U+FFFD, yielding a name that
    /// looks plausible and addresses nothing. Foundation's
    /// `string(withFileSystemRepresentation:length:)` returns `""` for the same
    /// input, and an empty path component resolves back to the parent
    /// directory — a real, existing path, which is far worse here. Both
    /// measured: on macOS 15.
    static func decodedName(bytes: UnsafeRawPointer, count: Int) -> String? {
        guard count > 0 else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: bytes, count: count),
                      encoding: .utf8)
    }

    /// Attributes arrive packed in the order they are declared in `attrlist`,
    /// preceded by the entry length and the set of attributes actually
    /// returned. Each field is stepped over only when its bit is present:
    /// a directory has no `ATTR_FILE_ALLOCSIZE`, so a fixed stride would
    /// misalign every later field for that entry.
    ///
    /// `ATTR_CMN_ERROR` is read FIRST, before `ATTR_CMN_NAME`, even though its
    /// bit value (0x20000000) is higher than NAME's (0x1). `man 2
    /// getattrlistbulk`: it "will be after ATTR_CMN_RETURNED_ATTRS attribute in
    /// the returned buffer", and the man page's own example parses it there.
    ///
    /// Measured: the kernel does not set the error bit for a
    /// successful entry — `returned.commonattr` is 0x80000409 for both a file
    /// and a directory — so the field is absent and the guarded read is
    /// skipped. Reading it in bit order therefore misparses only the entries
    /// the kernel reports an error for, which are exactly the ones this
    /// attribute exists to find. Nothing can force such an entry from a test,
    /// so no test covers that path.
    private static func parse(_ start: UnsafeRawPointer) -> ParsedEntry {
        var cursor = start.advanced(by: MemoryLayout<UInt32>.size)
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

        var failed = false
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            failed = cursor.loadUnaligned(as: UInt32.self) != 0
            cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
        }

        var name: String?
        var isDirectory = false
        var modified: Date?
        var sizeBytes: Int64 = 0

        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            let nameStart = cursor.advanced(by: Int(reference.attr_dataoffset))
            // `attr_length` includes the trailing NUL, which is not part of the name.
            let byteCount = max(0, Int(reference.attr_length) - 1)
            name = decodedName(bytes: nameStart, count: byteCount)
            cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
        }

        // On an errored entry only NAME and ERROR are valid, so stop here
        // rather than reading fields the kernel did not fill in.
        if failed { return .failed }

        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            isDirectory = cursor.loadUnaligned(as: fsobj_type_t.self) == UInt32(VDIR.rawValue)
            cursor = cursor.advanced(by: MemoryLayout<fsobj_type_t>.size)
        }
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let stamp = cursor.loadUnaligned(as: timespec.self)
            modified = Date(
                timeIntervalSince1970: TimeInterval(stamp.tv_sec)
                    + TimeInterval(stamp.tv_nsec) / 1_000_000_000
            )
            cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            sizeBytes = Int64(cursor.loadUnaligned(as: off_t.self))
        }

        // An entry the kernel listed but did not name is one we cannot address:
        // a hole in this listing, counted like an errored entry rather than
        // dropped. Only `.` and `..` are legitimately not entries.
        guard let name else { return .failed }
        guard name != ".", name != ".." else { return .ignored }
        return .entry(BulkEntry(
            name: name, isDirectory: isDirectory, sizeBytes: sizeBytes, modified: modified))
    }
}
