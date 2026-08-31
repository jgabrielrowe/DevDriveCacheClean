// Sources/DDCCCore/Safety/DeletionService.swift
import Foundation

public struct DeletionFailure<T: Deletable>: Sendable, Identifiable {
    public let id = UUID()
    public let result: T
    public let reason: String

    public init(result: T, reason: String) {
        self.result = result
        self.reason = reason
    }
}

public struct DeletionReport<T: Deletable>: Sendable {
    public let succeeded: [T]
    public let failed: [DeletionFailure<T>]
    /// Sum of the sizes of successful removals only — never the selection
    /// total. Accumulated with `DeletionService.addClamped`, which saturates
    /// rather than traps or goes negative — see that function's doc comment.
    public let bytesReclaimed: Int64

    public init(succeeded: [T], failed: [DeletionFailure<T>], bytesReclaimed: Int64) {
        self.succeeded = succeeded
        self.failed = failed
        self.bytesReclaimed = bytesReclaimed
    }

    public var isCompleteSuccess: Bool { failed.isEmpty }
}

/// Removes paths, re-validating every one immediately beforehand.
///
/// `PathGuard` already filtered the scan, so this second check is redundant by
/// design: it means a selection-UI defect, a stale result, or a path swapped
/// between scan and delete cannot produce an unguarded removal. Confirming
/// existence here also closes the time-of-check/time-of-use window.
public enum DeletionService {

    /// Seam over the two filesystem operations this service performs, plus
    /// the existence probe, so tests can pin behaviour — most importantly,
    /// that `permanently: true` and `permanently: false` really invoke two
    /// different operations — without touching the real macOS Trash (whose
    /// availability and effects vary by volume). Not `public`: callers
    /// outside the module always get `.live`.
    struct FileOperations {
        var fileExists: (String) -> Bool
        var removeItem: (URL) throws -> Void
        /// Returns the URL the item was actually moved to inside the Trash —
        /// `removeItem` has no destination to report, and this asymmetry is
        /// what pins `live`'s two bindings apart from each other (see
        /// `liveTrashItemActuallyTrashesAndReportsWhereItWent` in
        /// `DeletionServiceTests`). `delete` discards the value today.
        var trashItem: (URL) throws -> URL?

        /// Moves an item the user does not own to the Trash, authenticating
        /// first. Separate from `trashItem` because it is a different
        /// mechanism, not a flag on the same one:
        /// `FileManager.trashItem` refuses a root-owned item outright, so the
        /// live binding hands the move to Finder, which prompts for Touch ID
        /// or an admin password and performs it with its own authority. The
        /// item lands in the Trash and can be put back.
        /// Defaulted so that a caller which never sets it fails closed: an
        /// authenticated removal is opt-in, and a seam that silently did
        /// nothing would report an app as removed while it sat on disk.
        var authenticatedTrashItem: (URL) throws -> Void = { _ in
            throw FinderTrash.Failure.finderReported(
                "Authenticated removal is not available here.")
        }

        // Computed, not a stored `static let`: a stored global of this
        // non-`Sendable`, closure-holding type would need `Sendable`
        // conformance, which would force every closure here — including
        // test spies — to be `@Sendable` and unable to capture a plain
        // local `var`. `delete` only uses the value synchronously on the
        // caller's thread, so there's no concurrency to be safe against.
        static var live: FileOperations {
            FileOperations(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                removeItem: { url in try FileManager.default.removeItem(at: url) },
                trashItem: { url in
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                    return resultingURL as URL?
                },
                authenticatedTrashItem: { url in try FinderTrash.trash(url) }
            )
        }
    }

    public static func delete<T: Deletable>(
        _ results: [T],
        permanently: Bool,
        in context: PathGuard.Context
    ) -> DeletionReport<T> {
        delete(results, permanently: permanently, in: context, fileOperations: .live)
    }

    static func delete<T: Deletable>(
        _ results: [T],
        permanently: Bool,
        in context: PathGuard.Context,
        fileOperations: FileOperations
    ) -> DeletionReport<T> {
        var succeeded: [T] = []
        var failed: [DeletionFailure<T>] = []
        var bytesReclaimed: Int64 = 0
        var seenPaths: Set<String> = []

        for result in results {
            // Uses `Candidate.normalizedPathKey(for:)` rather than a
            // hand-rolled key: `delete` is public API, and two `ScanResult`s
            // for the same path can carry different URL spellings
            // (directory-hinted or not), which must still compare equal.
            let pathString = Candidate.normalizedPathKey(for: result.path)

            // The same path submitted twice in one batch must be attempted
            // only once: a second attempt would find the first one's outcome
            // (path already gone) and record a contradictory result for the
            // same item, making `isCompleteSuccess` lie about a batch that
            // fully succeeded. Later duplicates are dropped before touching
            // the guard, the filesystem, or either output array.
            guard seenPaths.insert(pathString).inserted else { continue }

            // Locked informational rows are never deletable, whatever was selected.
            guard result.isDeletable else {
                failed.append(DeletionFailure(
                    result: result,
                    reason: "DevDriveCacheClean cannot remove this item."
                ))
                continue
            }

            let verdict = PathGuard.evaluate(
                result.path, removability: result.removability, in: context)

            // The second of the two keys an authenticated removal needs. The
            // row claiming `requiresAuthentication` is the first; this asks
            // the guard, here and now, whether root ownership really is the
            // only thing refusing the path. Both are required, so a stale
            // result or a selection-UI defect cannot escalate an ordinary row
            // into a route that removes an application.
            let authenticating =
                verdict != .allowed && result.requiresAuthentication
                && PathGuard.requiresElevation(
                    result.path, removability: result.removability, in: context)

            guard verdict == .allowed || authenticating else {
                // Existence is checked only to pick the failure message, never
                // to change the verdict: a vanished path fails one of the
                // guard's fail-closed checks for an unrelated reason
                // (`isRootOwned` can't stat it, so it reads "owned by root"),
                // and this substitutes the clearer message.
                let reason: String
                if fileOperations.fileExists(pathString) == false {
                    reason = "No longer exists — it may have been removed already."
                } else if case .refused(let detail) = verdict {
                    reason = "Refused: \(detail)."
                } else {
                    reason = "Refused: this item requires privileges DevDriveCacheClean does not have."
                }
                failed.append(DeletionFailure(result: result, reason: reason))
                continue
            }

            guard fileOperations.fileExists(pathString) else {
                failed.append(DeletionFailure(
                    result: result,
                    reason: "No longer exists — it may have been removed already."
                ))
                continue
            }

            // No permanent route exists for these, and one must not be
            // improvised. An unprivileged recursive delete of a root-owned
            // tree stops at the first entry it cannot unlink, and Finder's
            // authenticated route only ever moves an item to the Trash — so
            // offering "delete permanently" here would either fail partway or
            // quietly do something other than what it says.
            if authenticating, permanently {
                failed.append(DeletionFailure(
                    result: result,
                    reason: "Removing this app needs your authentication, which can only move it to the Trash. Use Move to Trash, then empty the Trash."
                ))
                continue
            }

            do {
                if permanently {
                    try fileOperations.removeItem(result.path)
                } else if authenticating {
                    try fileOperations.authenticatedTrashItem(result.path)
                } else {
                    _ = try fileOperations.trashItem(result.path)
                }
                succeeded.append(result)
                bytesReclaimed = addClamped(bytesReclaimed, result.sizeBytes)
            } catch {
                failed.append(DeletionFailure(
                    result: result, reason: error.localizedDescription))
            }
        }

        return DeletionReport(
            succeeded: succeeded, failed: failed, bytesReclaimed: bytesReclaimed)
    }

    /// Adds `increment` to `total`, saturating at `Int64.max` instead of
    /// trapping on overflow, and treating a negative `increment` as zero.
    ///
    /// A plain `+=` traps on overflow — after the files for that batch have
    /// already been removed, which would destroy the only record
    /// (`DeletionReport`) of what happened. Saturating keeps the report
    /// alive. A negative `sizeBytes` is clamped to zero rather than
    /// subtracted, so one corrupt entry can't understate what other, valid
    /// entries in the same batch genuinely reclaimed.
    private static func addClamped(_ total: Int64, _ increment: Int64) -> Int64 {
        let sanitized = max(increment, 0)
        let (sum, overflowed) = total.addingReportingOverflow(sanitized)
        return overflowed ? Int64.max : sum
    }
}
