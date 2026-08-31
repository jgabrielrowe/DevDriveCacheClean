import Foundation

public enum ScanState: Sendable {
    case idle
    /// Counts are optional because neither scanner has them while walking:
    /// `ScanCoordinator` reports a phase and a path, `FileFinder` a path. A
    /// non-optional payload would make a view model invent a zero and the view
    /// render it.
    case scanning(currentPath: String, itemsFound: Int?, bytesFound: Int64?)
    /// Sizing the resolved survivors. Determinate, because the survivor count
    /// is known before this stage begins.
    case measuring(progress: MeasureProgress)
    /// Non-defaulted associated values are the mechanism, not an inconvenience:
    /// every construction site must supply completeness and every `switch` must
    /// decide what to do with it, so a status surface added later cannot
    /// silently omit the caveat.
    case completed(totalItems: Int, totalBytes: Int64, duration: TimeInterval,
                   completeness: ScanCompleteness)
    /// Stopped by the user. Carries what the run had found by then — those rows
    /// are individually true; only their totality is not.
    case cancelled(itemsFound: Int, bytesFound: Int64, completeness: ScanCompleteness)

    /// Why a results list has no rows, for the view that must say so.
    ///
    /// Exists because choosing that message with a chain of `if case` tests and
    /// a trailing `else` has now failed twice: first a stopped run was
    /// described as having found nothing, then a run that was *still going* was
    /// too. Both times the state that fell through was the one nobody
    /// remembered to add a branch for.
    ///
    /// The `switch` below is exhaustive and has no `default`, so a new
    /// `ScanState` case cannot compile until this file decides what it means.
    /// That is the whole point of the type: the compiler now asks the question
    /// that a trailing `else` silently answered wrong.
    public var emptyResultsReason: EmptyResultsReason {
        switch self {
        case .idle: return .notSearchedYet
        case .scanning, .measuring: return .stillSearching
        case .cancelled: return .stopped
        case .completed: return .searchedAndFoundNothing
        }
    }

    public var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    /// True while a scan is running in *either* stage. Gate the Scan button on
    /// this rather than `isScanning`, which covers discovery only.
    public var isActive: Bool {
        switch self {
        case .scanning, .measuring: return true
        case .idle, .completed, .cancelled: return false
        }
    }
}

/// What an empty results list means, which is four different things.
///
/// Kept apart from `ScanState` itself because the distinction the view needs is
/// coarser: `.scanning` and `.measuring` are one answer here and two answers
/// everywhere else. Collapsing them at the point of use is what let a third
/// meaning hide inside a trailing `else`.
public enum EmptyResultsReason: Sendable, Equatable {
    /// Nothing has been asked yet. Not a result.
    case notSearchedYet
    /// A run is under way right now. Emphatically not a result: the view must
    /// not state an answer to a question still being asked.
    case stillSearching
    /// The user stopped it. The rows found so far are true; their totality is
    /// not.
    case stopped
    /// It ran to completion and there was genuinely nothing. The only one of
    /// the four that is an answer.
    case searchedAndFoundNothing
}
