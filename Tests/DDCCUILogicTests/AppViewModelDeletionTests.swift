import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

@MainActor
private func modelWithResults(_ count: Int) -> (AppViewModel, [ScanResult]) {
    let model = AppViewModel()
    let results = (0..<count).map { index in
        ScanResult(
            path: URL(fileURLWithPath: "/tmp/ddcc-delete-\(index)"),
            category: .xcode,
            tier: .safe,
            removability: .removable,
            sizeBytes: Int64(1_000 * (index + 1)),
            lastModified: nil,
            displayName: "row-\(index)",
            partialRead: false,
            unreadablePaths: [],
            isDeletable: true
        )
    }
    model.results = results
    for result in results { model.toggleSelection(result.id) }
    return (model, results)
}

/// `deleteSelected` had no coverage at all, which is the same fact as its
/// report reaching no view: nothing read `lastDeletionReport`, so nothing
/// noticed it was never asserted on either. A succeeded row must leave both the
/// list and the selection; a failed row must stay in both, so the user can see
/// it and retry it.
@Test @MainActor func deletingPartitionsSucceededAndFailedRows() {
    let (model, results) = modelWithResults(2)

    let failure = DeletionFailure(result: results[1], reason: "boom")
    model.deleteResults = { _, _, _ in
        DeletionReport(succeeded: [results[0]], failed: [failure],
                       bytesReclaimed: results[0].sizeBytes)
    }

    model.deleteSelected()

    #expect(model.results.map(\.id) == [results[1].id])
    #expect(model.selectedResultIDs == [results[1].id])
    #expect(model.lastDeletionReport?.failed.map(\.result.id) == [results[1].id])
}

/// The banner is driven entirely by `lastDeletionReport`. A fully successful
/// deletion must leave nothing behind for it to render, or every clean delete
/// would show an empty warning.
@Test @MainActor func aFullySuccessfulDeletionLeavesNoFailures() {
    let (model, results) = modelWithResults(2)
    model.deleteResults = { _, _, _ in
        DeletionReport(succeeded: results, failed: [], bytesReclaimed: 0)
    }

    model.deleteSelected()

    #expect(model.results.isEmpty)
    #expect(model.selectedResultIDs.isEmpty)
    #expect(model.lastDeletionReport?.failed.isEmpty == true)
}

/// The Caches view can delete permanently, unlike the Files view. The notice
/// must not claim rows were "moved to the Trash" when they were not, and the
/// wording is captured at deletion time rather than read back from the
/// confirmation sheet's toggle, which the user can change afterwards.
@Test @MainActor func theRecordedOperationMatchesWhatWasAttempted() {
    let (model, _) = modelWithResults(1)
    model.deleteResults = { _, _, _ in
        DeletionReport(succeeded: [], failed: [], bytesReclaimed: 0)
    }

    model.deleteSelected(permanently: false)
    #expect(model.lastDeletionOperation == "moved to the Trash")

    model.deleteSelected(permanently: true)
    #expect(model.lastDeletionOperation == "deleted permanently")
}

/// The seam must actually carry the flag through, or the wording above could be
/// right while the deletion was wrong — the more dangerous half of the pair.
@Test @MainActor func thePermanentFlagReachesTheDeleter() {
    let (model, _) = modelWithResults(1)
    final class Box: @unchecked Sendable { var seen: [Bool] = [] }
    let box = Box()
    model.deleteResults = { _, permanently, _ in
        box.seen.append(permanently)
        return DeletionReport(succeeded: [], failed: [], bytesReclaimed: 0)
    }

    model.deleteSelected(permanently: true)
    model.deleteSelected(permanently: false)

    #expect(box.seen == [true, false])
}

/// A stale failure banner outliving the run it described reports an error about
/// rows that are no longer listed. `FinderViewModel.startFind` has cleared this
/// since the finder shipped, with the reason in a comment; `startScan` never
/// did, so backporting the notice without this would ship the stale-banner bug
/// the Files view already fixed.
@Test @MainActor func startingAScanClearsTheLastDeletionReport() throws {
    let (model, results) = modelWithResults(1)
    model.lastDeletionReport = DeletionReport(
        succeeded: [], failed: [DeletionFailure(result: results[0], reason: "boom")],
        bytesReclaimed: 0)

    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    model.scanPath = tempRoot

    model.startScan()
    #expect(model.lastDeletionReport == nil)
    model.cancelScan()
}

/// The sheet read "Delete 1 items?" — an ungrammatical confirmation on the
/// one screen where the app asks a user to trust it with a destructive
/// action. `UninstallDetailView` had inflected its own delete title all
/// along; this was the outlier.
@MainActor @Test func theDeleteTitleInflectsItsNoun() {
    let (one, _) = modelWithResults(1)
    #expect(one.deleteConfirmationTitle == "Delete 1 item?")

    let (three, _) = modelWithResults(3)
    #expect(three.deleteConfirmationTitle == "Delete 3 items?")
}
