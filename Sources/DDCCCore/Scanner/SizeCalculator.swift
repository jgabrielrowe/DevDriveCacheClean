import Foundation

/// Bytes on disk, plus what could not be read and what was not a kind we read.
public struct SizeMeasurement: Sendable, Equatable {
    public let bytes: Int64
    /// Directories inside this one that refused enumeration, each named.
    ///
    /// Named rather than tallied because a count cannot be deduplicated. The
    /// walk reaches the same sealed directories from a different direction, and
    /// one hole in the disk reported by two engines has to collapse to one —
    /// which `RefusalSet` can do with paths and cannot do with an `Int`.
    ///
    /// Keyed through `Candidate.normalizedPathKey`, which is what makes the two
    /// engines' spellings comparable at all.
    public let unreadablePaths: Set<String>
    /// Exists, but is not a kind we measure — a symlink, socket, fifo or device
    /// node. Not a denial: nothing refused us, the path is right there. Kept
    /// apart from `unreadablePaths` rather than counted as one, because a
    /// refusal count that includes things nobody refused can never be exact.
    ///
    /// It still drives `partialRead`, so nothing a user sees changes here.
    /// Reporting it as "could not be read" is inaccurate; correcting that is
    /// a follow-up, not fixed here.
    public let unmeasurableKind: Bool
    /// Bytes this item holds but does not own outright: content reachable by a
    /// hard link from somewhere outside the measured tree, which survives the
    /// delete and so frees nothing.
    ///
    /// Kept apart from `bytes` rather than folded into it, because the two
    /// answer different questions. `bytes` answers "what will removing this
    /// free"; this answers "what did I decline to promise you, and why". A
    /// pnpm `node_modules` linking into a store is the ordinary case: nearly
    /// all of its apparent size is here, not in `bytes`.
    ///
    /// It is deliberately **not** part of `partialRead`. Nothing refused us
    /// and nothing was unreadable — the walk saw every byte and reached a
    /// finished answer about who owns them. A floor and a full accounting are
    /// different claims and must not share a flag.
    public let sharedBytesWithheld: Int64

    public init(bytes: Int64, unreadablePaths: Set<String>, unmeasurableKind: Bool,
                sharedBytesWithheld: Int64) {
        self.bytes = bytes
        self.unreadablePaths = unreadablePaths
        self.unmeasurableKind = unmeasurableKind
        self.sharedBytesWithheld = sharedBytesWithheld
    }

    public static let zero = SizeMeasurement(
        bytes: 0, unreadablePaths: [], unmeasurableKind: false, sharedBytesWithheld: 0)

    /// True when the byte count is a floor rather than a total.
    public var partialRead: Bool { !unreadablePaths.isEmpty || unmeasurableKind }
}

/// What one sizing attempt produced.
///
/// An enum rather than a flag on `SizeMeasurement`, because the defect this
/// type exists to close is precisely that a caller can ignore a flag. Four
/// distinct situations would otherwise be indistinguishable from a legitimate
/// zero — cancelled before the walk, cancelled during it, metadata refused,
/// enumerator refused — leaving a caller to read `bytes == 0` and drop a row
/// it should have kept. `ScanCompleteness.exact`
/// carries the same reasoning for the same reason: every construction site
/// states what it knows, so nothing inherits a certainty it did not earn.
public enum SizeOutcome: Sendable, Equatable {
    /// Sized. The walk completed. May still be a floor rather than a total —
    /// see `SizeMeasurement.partialRead`.
    case measured(SizeMeasurement)
    /// Cancellation arrived before or during the walk. Never sized. A caller
    /// must count this, not drop it: the candidate is real and its bytes are
    /// missing from the total.
    case cancelled
    /// The path exists but could not be read at all — its metadata was refused,
    /// or the enumerator could not be created. Distinct from
    /// `.measured(.zero)`, which means the walk succeeded and genuinely found
    /// nothing. A path that does not exist is `.measured(.zero)`, not this:
    /// absence is not denial.
    case unmeasurable

    /// The measurement, for the one case that has one. Optional rather than
    /// defaulting to `.zero`, so reading it is an explicit act.
    public var measurement: SizeMeasurement? {
        guard case .measured(let measurement) = self else { return nil }
        return measurement
    }
}

/// A file's identity on disk: which volume, and which inode on it.
///
/// Both halves are load-bearing. Inode numbers are unique per volume, not per
/// machine, and a measured tree can span a mount point — so keying on the inode
/// alone would fuse two unrelated files into one and undercount.
///
/// Read with `lstat` rather than `URLResourceKey.fileIdentifierKey` because
/// this needs the device too, and the volume identifier arrives as an opaque
/// `NSCopying` that is awkward to hash. The syscall is affordable precisely
/// because it only ever fires for a file with more than one link.
private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init?(of url: URL) {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        device = status.st_dev
        inode = status.st_ino
    }
}

/// One multiply-linked file, and how much of it this tree can account for.
private struct LinkedFile {
    let bytes: Int64
    /// `st_nlink`: how many names exist for this inode anywhere on the volume.
    let linkCount: Int
    /// How many of those names the walk actually found inside the measured tree.
    var linksSeen: Int

    /// True when every name for this inode lives in the tree being measured,
    /// which is the only case where deleting the tree releases the blocks.
    var treeHoldsEveryLink: Bool { linksSeen >= linkCount }
}

public enum SizeCalculator {

    /// Total allocated size of `url`, however it happens to exist.
    ///
    /// - A directory: everything inside, hidden files and bundle contents
    ///   included (DerivedData is mostly bundles).
    /// - A regular file: its own allocated size.
    /// - A missing path: `.measured(.zero)`. Absence is not a denial, and
    ///   `unreadablePaths` drives `partialRead` and `RefusalSet` — counting
    ///   absence there would fire both for paths that were never present.
    /// - A path that exists but whose metadata cannot be read: `.unmeasurable`,
    ///   so a caller can tell "nothing there" from "something there I could not
    ///   see". See `SizeOutcome`.
    /// - Anything else that exists (symlink, socket, fifo, device node) is not
    ///   measured: zero bytes with `unmeasurableKind: true`, so `partialRead`
    ///   is set without entering `unreadablePaths`, which is for denials.
    ///   Symlinks are not followed — `PathGuard` never treats one as a
    ///   removable leaf, and resolving here would make the sizer and the guard
    ///   disagree about what the path means. Do not resolve the link to "fix"
    ///   this.
    ///
    /// Cancellation is checked before the walk and every
    /// `cancellationCheckInterval` entries after. A cancelled walk returns
    /// `.cancelled`, never a truncated count or `.measured(.zero)`, which a
    /// caller would read as empty. A regular file is one stat with no walk to
    /// abandon, so it returns its real size even under cancellation.
    public static func measure(at url: URL) -> SizeOutcome {
        let statKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .linkCountKey,
        ]

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: statKeys)
        } catch {
            // Absence is not denial: a path that was never there measures to a
            // real, honest zero. A path that exists but refused us is a hole in
            // the total and must say so.
            return PathAccess.isAbsent(error) ? .measured(.zero) : .unmeasurable
        }

        if values.isRegularFile == true {
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            // A single file is a tree holding exactly one link. If the inode
            // has others, they are all outside by definition, they survive
            // removing this name, and the blocks do not come back. Reporting
            // the allocated size here would promise space that deleting cannot
            // deliver — the whole defect this rule exists to close.
            if (values.linkCount ?? 1) > 1 {
                return .measured(SizeMeasurement(
                    bytes: 0, unreadablePaths: [], unmeasurableKind: false,
                    sharedBytesWithheld: bytes))
            }
            return .measured(SizeMeasurement(
                bytes: bytes, unreadablePaths: [], unmeasurableKind: false,
                sharedBytesWithheld: 0))
        }

        guard values.isDirectory == true else {
            // Exists but is neither a regular file nor a directory — most
            // often a symlink, since these keys report the link itself
            // rather than following it. Flagged, not silently zero, and not
            // as a denial: see the doc comment above.
            return .measured(SizeMeasurement(
                bytes: 0, unreadablePaths: [], unmeasurableKind: true,
                sharedBytesWithheld: 0))
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .linkCountKey,
        ]

        // A class so the errorHandler closure and this scope share one set.
        final class Failures {
            var paths: Set<String> = []
        }
        let failures = Failures()

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { failedURL, _ in
                // Keyed exactly as `FileScanner.walk`'s errorHandler keys its
                // own refusals. That is not a style choice: the enumerator
                // reports a refused descendant as `/private/var/…` while the
                // walk reports `/var/…`, and `normalizedPathKey`'s
                // `standardizedFileURL` is what reconciles the two. Store the
                // raw `failedURL.path` here and one sealed directory is two
                // refusals again.
                //
                // Unlike `FileScanner`, this does not filter `PathAccess
                // .isAbsent` — it never has, and adding the filter would move
                // the reported number. Recorded as a follow-up rather than
                // changed under cover of this one.
                failures.paths.insert(Candidate.normalizedPathKey(for: failedURL))
                return true   // keep going, but record the denial
            }
        ) else {
            return .unmeasurable
        }

        // Checked once here too (not just in the loop below) so a directory
        // smaller than `cancellationCheckInterval` isn't exempt from the
        // cancellation contract.
        if Task.isCancelled {
            return .cancelled
        }

        var totalBytes: Int64 = 0
        // Only files with more than one name land here, which is why carrying a
        // dictionary through the hottest loop in the app is affordable: on an
        // ordinary tree it stays empty, and on a pnpm store or a Homebrew cellar
        // it holds one entry per shared inode rather than one per entry walked.
        var linkedFiles: [FileIdentity: LinkedFile] = [:]
        var entriesSinceCancellationCheck = 0
        for case let fileURL as URL in enumerator {
            // This is the hottest loop in the app — a large tree (DerivedData,
            // node_modules, a VM bundle) can have hundreds of thousands of
            // entries — so `Task.isCancelled` is checked every
            // `cancellationCheckInterval` entries rather than every one.
            entriesSinceCancellationCheck += 1
            if entriesSinceCancellationCheck >= cancellationCheckInterval {
                entriesSinceCancellationCheck = 0
                if Task.isCancelled {
                    return .cancelled
                }
            }

            guard let values = try? fileURL.resourceValues(forKeys: keys) else {
                // Measured: a `chmod 000` FILE still stats fine —
                // stat needs traverse on the parent, not read on the file — so
                // this arm is not the one a sealed file takes. It records
                // the entry it could not stat.
                failures.paths.insert(Candidate.normalizedPathKey(for: fileURL))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)

            // The overwhelmingly common case: one name, one owner, count it and
            // move on without touching the dictionary or spending a syscall.
            let linkCount = values.linkCount ?? 1
            guard linkCount > 1 else {
                totalBytes += bytes
                continue
            }

            guard let identity = FileIdentity(of: fileURL) else {
                // The file stats through Foundation but not through `lstat` —
                // it was almost certainly unlinked between the two calls.
                // Counting it keeps the old behaviour for a case that cannot be
                // adjudicated, and the alternative (silently withholding it)
                // would understate for a reason nobody could check.
                totalBytes += bytes
                continue
            }

            if linkedFiles[identity] == nil {
                linkedFiles[identity] = LinkedFile(
                    bytes: bytes, linkCount: linkCount, linksSeen: 0)
            }
            linkedFiles[identity]?.linksSeen += 1
        }

        // Settle the shared inodes now the walk knows how many of each one's
        // names it actually found. An inode the tree holds outright is counted
        // once, however many entries pointed at it. One with names living
        // elsewhere is counted zero and disclosed instead: those blocks outlive
        // the delete, so promising them would be the same inflation this
        // measurement exists to avoid.
        var sharedBytesWithheld: Int64 = 0
        for file in linkedFiles.values {
            if file.treeHoldsEveryLink {
                totalBytes += file.bytes
            } else {
                sharedBytesWithheld += file.bytes
            }
        }

        return .measured(SizeMeasurement(
            bytes: totalBytes, unreadablePaths: failures.paths, unmeasurableKind: false,
            sharedBytesWithheld: sharedBytesWithheld))
    }

    /// How many enumerator entries pass between `Task.isCancelled` checks
    /// (plus one check before the first entry). 256 keeps the check off the
    /// per-entry hot path while capping cancellation latency to roughly a
    /// couple hundred stat calls — milliseconds, not the seconds a full walk
    /// of an 11 GB bundle would take.
    private static let cancellationCheckInterval = 256

    /// The directory's own modification timestamp. Reflects only direct
    /// child additions and removals, not writes deeper in the tree — a
    /// cheap approximation of staleness, not "most recent change anywhere
    /// inside".
    public static func lastModified(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}
