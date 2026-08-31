import Testing
import Foundation
@testable import DDCCCore

private let everyState: [ScanState] = [
    .idle,
    .scanning(currentPath: "/tmp", itemsFound: nil, bytesFound: nil),
    .measuring(progress: MeasureProgress(completed: 1, total: 10)),
    .completed(totalItems: 0, totalBytes: 0, duration: 1, completeness: .exact),
    .cancelled(itemsFound: 0, bytesFound: 0, completeness: .exact),
]

/// The defect this replaces: a list with no rows chose its placeholder with
/// `if cancelled / else if idle / else`, so a run still in progress fell to the
/// `else` and asserted "No Files Found" for the whole duration of the search.
/// A state that is still looking must never be described as having looked.
@Test func aRunInProgressIsNeverReportedAsHavingFoundNothing() {
    #expect(ScanState.scanning(currentPath: "/tmp", itemsFound: nil, bytesFound: nil)
        .emptyResultsReason == .stillSearching)
    #expect(ScanState.measuring(progress: MeasureProgress(completed: 1, total: 10))
        .emptyResultsReason == .stillSearching)
}

@Test func eachRemainingStateKeepsItsOwnAnswer() {
    #expect(ScanState.idle.emptyResultsReason == .notSearchedYet)
    #expect(ScanState.cancelled(itemsFound: 0, bytesFound: 0, completeness: .exact)
        .emptyResultsReason == .stopped)
    #expect(ScanState.completed(totalItems: 0, totalBytes: 0, duration: 1, completeness: .exact)
        .emptyResultsReason == .searchedAndFoundNothing)
}

/// Four distinct facts, four distinct answers. Two states sharing a reason is
/// how "stopped" and "found nothing" were conflated in the first place, and
/// how "searching" joined them later.
@Test func theFourReasonsAreMutuallyExclusiveAcrossEveryState() {
    let reasons = everyState.map(\.emptyResultsReason)
    // `.scanning` and `.measuring` are deliberately the same reason — both are
    // "still looking" — so five states produce four distinct answers.
    #expect(Set(reasons).count == 4)
    #expect(reasons.filter { $0 == .stillSearching }.count == 2)
}
