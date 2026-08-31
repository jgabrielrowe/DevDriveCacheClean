import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

@MainActor
private func modelWithFiles(_ count: Int) -> (FinderViewModel, [FoundFile]) {
    let model = FinderViewModel()
    let files = (0..<count).map { index in
        FoundFile(
            path: URL(fileURLWithPath: "/tmp/found-\(index).bin"),
            sizeBytes: Int64(1_000 * (index + 1)),
            lastModified: Date(timeIntervalSinceNow: -100_000),
            isBundle: false
        )
    }
    model.replaceFiles(files)
    return (model, files)
}

@Test @MainActor func newFinderResultsAreNeverPreSelected() {
    let (model, _) = modelWithFiles(5)
    #expect(model.selectedFileIDs.isEmpty)
    #expect(model.selectedFiles.isEmpty)
}

/// The headline safety property, checked on the path that actually produces
/// rows. Asserting only against a hand-assigned `files` array would let a
/// regression that pre-selected results inside `finish()` — the one place a
/// completed run's rows arrive — pass unnoticed.
@Test @MainActor func finishingARunNeverPreSelectsTheResults() {
    let model = FinderViewModel()
    let files = (0..<3).map { index in
        FoundFile(
            path: URL(fileURLWithPath: "/tmp/finish-\(index).bin"),
            sizeBytes: Int64(1_000 * (index + 1)),
            lastModified: Date(timeIntervalSinceNow: -100_000),
            isBundle: false
        )
    }
    let report = FinderReport(
        files: files, outcome: .finished, unreadableDirectoryCount: 0,
        unmeasuredCount: 0, duration: 1.0)

    model.finish(report)

    #expect(model.files.map(\.id) == files.map(\.id))
    #expect(model.selectedFileIDs.isEmpty)
}

@Test @MainActor func togglingSelectsAndDeselectsOneRow() {
    let (model, files) = modelWithFiles(3)
    model.toggleSelection(files[1].id)
    #expect(model.selectedFileIDs == [files[1].id])
    model.toggleSelection(files[1].id)
    #expect(model.selectedFileIDs.isEmpty)
}

@Test @MainActor func togglingAnUnknownIDSelectsNothing() {
    let (model, _) = modelWithFiles(3)
    model.toggleSelection(UUID())
    #expect(model.selectedFileIDs.isEmpty)
}

@Test @MainActor func selectedSizeSumsOnlySelectedRows() {
    let (model, files) = modelWithFiles(3)
    model.toggleSelection(files[0].id)   // 1_000
    model.toggleSelection(files[2].id)   // 3_000
    #expect(model.selectedSize == 4_000)
}

@Test @MainActor func finderDeselectAllClearsEverything() {
    let (model, files) = modelWithFiles(3)
    for file in files { model.toggleSelection(file.id) }
    model.deselectAll()
    #expect(model.selectedFileIDs.isEmpty)
}

/// Starting a find must not carry a stale selection into a new result set,
/// where the ids would no longer correspond to anything on screen.
///
/// `searchRoot` is pointed at a fresh temporary directory rather than left
/// at its `$HOME` default: `withTempDirectory` lives in the DDCCCoreTests
/// support sources and is not reachable from this target, and a real walk
/// of the home directory during `swift test` is exactly what this fix is
/// meant to avoid — `cancelFind()` only lands at the next directory
/// boundary, so a home-directory walk would run for real before stopping.
@Test @MainActor func startingAFindClearsTheSelection() throws {
    let (model, files) = modelWithFiles(3)
    model.toggleSelection(files[0].id)

    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    model.searchRoot = tempRoot

    model.startFind()
    #expect(model.selectedFileIDs.isEmpty)
    model.cancelFind()
}

/// A failed-Trash banner is driven entirely by `lastDeletionReport`. Left in
/// place across a new run, it would show a stale reason over an entirely
/// valid result set, for files no longer even on screen. Starting a find
/// must clear it just as it clears the stale selection above.
@Test @MainActor func startingAFindClearsTheLastDeletionReport() throws {
    let (model, files) = modelWithFiles(1)
    let failure = DeletionFailure(result: files[0], reason: "boom")
    model.lastDeletionReport = DeletionReport(
        succeeded: [], failed: [failure], bytesReclaimed: 0)

    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    model.searchRoot = tempRoot

    model.startFind()
    #expect(model.lastDeletionReport == nil)
    model.cancelFind()
}

/// Removal has no coverage otherwise, because `DeletionService` was called
/// inline. The seam lets a test prove the partition without touching the
/// real filesystem: a succeeded row must leave both the list and the
/// selection, a failed row must stay in both, and the report must be kept
/// either way.
@Test @MainActor func trashingPartitionsSucceededAndFailedRows() {
    let (model, files) = modelWithFiles(2)
    model.toggleSelection(files[0].id)
    model.toggleSelection(files[1].id)

    let failure = DeletionFailure(result: files[1], reason: "boom")
    let injectedReport = DeletionReport(
        succeeded: [files[0]], failed: [failure], bytesReclaimed: files[0].sizeBytes)
    model.deleteFiles = { _, _ in injectedReport }

    model.moveSelectedToTrash()

    #expect(model.files.map(\.id) == [files[1].id])
    #expect(model.selectedFileIDs == [files[1].id])
    #expect(model.lastDeletionReport?.succeeded.map(\.id) == [files[0].id])
    #expect(model.lastDeletionReport?.failed.map(\.result.id) == [files[1].id])
}

/// `moveSelectedToTrash` must build its `PathGuard.Context` from the root the
/// run actually used, not the LIVE `searchRoot`. Changing the root after a run
/// finished — without re-running — otherwise refuses every row as "outside the
/// scan root", because the context no longer describes the tree the rows came
/// from.
///
/// `searchRoot` is pointed at a temp directory for the same reason
/// `startingAFindClearsTheSelection` above does: a real walk of `$HOME`
/// during `swift test` is not something this test wants to trigger. Root A's
/// context is derived through `PathGuard.Context` itself (rather than
/// hand-standardizing the temp path) so the assertion does not have to
/// duplicate that type's own symlink-resolution and standardization logic.
@Test @MainActor func trashingAfterRootChangeStillEvaluatesAgainstTheRunRoot() throws {
    let model = FinderViewModel()

    let rootA = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootA) }
    model.searchRoot = rootA

    model.startFind()
    #expect(model.lastRunRoot == rootA)
    model.cancelFind()

    let rootB = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    model.searchRoot = rootB

    final class CapturedContext: @unchecked Sendable { var value: PathGuard.Context? }
    let captured = CapturedContext()
    model.deleteFiles = { _, context in
        captured.value = context
        return DeletionReport(succeeded: [], failed: [], bytesReclaimed: 0)
    }

    model.moveSelectedToTrash()

    let expectedRoot = PathGuard.Context(scanRoot: rootA, declaredPaths: []).scanRoot
    #expect(captured.value?.scanRoot == expectedRoot)
}

/// The safety property that cannot be allowed to regress. Trashing is the
/// only removal the finder offers; nothing in this type — or any Files-view
/// view that could call `DeletionService` directly instead of going through
/// this view model — may request a permanent delete.
///
/// Originally scanned only `FinderViewModel.swift`, which would pass even if
/// a view under `Sources/DDCCUI/Views/` called `DeletionService.delete`
/// directly with `permanently: true`, bypassing the view model entirely.
/// Widened to every Files-view source file for that reason.
///
/// Derived from `#filePath` rather than a repo-relative path, so a wrong
/// working directory fails this one test instead of crashing the whole
/// run: this file lives at Tests/DDCCUILogicTests/FinderViewModelTests.swift,
/// so its grandparent directory is the package root regardless of where
/// `swift test` was invoked from.
@Test @MainActor func finderNeverRequestsPermanentDeletion() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FinderViewModelTests.swift -> DDCCUILogicTests
        .deletingLastPathComponent()  // DDCCUILogicTests -> Tests
        .deletingLastPathComponent()  // Tests -> package root
    let relativePaths = [
        "Sources/DDCCUI/ViewModels/FinderViewModel.swift",
        "Sources/DDCCUI/Views/FinderListView.swift",
        "Sources/DDCCUI/Views/FinderDetailView.swift",
        "Sources/DDCCUI/Views/FinderToolbar.swift",
        "Sources/DDCCUI/Views/TrashConfirmationSheet.swift",
    ]

    for relativePath in relativePaths {
        let sourceURL = packageRoot.appending(path: relativePath)
        let source = try #require(try? String(contentsOf: sourceURL, encoding: .utf8))
        #expect(source.contains("permanently: true") == false, "\(relativePath) requests permanent deletion")
    }

    let viewModelSource = try #require(
        try? String(
            contentsOf: packageRoot.appending(path: relativePaths[0]), encoding: .utf8))
    #expect(viewModelSource.contains("permanently: false"))
}

/// The tray reads `state`, so a report's completeness that never reaches the
/// state is a fact gathered and then dropped — which is exactly how "0 items -
/// Zero KB" came to render for a run that could not read half the disk.
@Test @MainActor func finishCarriesTheReportsCompletenessIntoTheState() {
    let model = FinderViewModel()
    model.finish(FinderReport(
        files: [], outcome: .finished, unreadableDirectoryCount: 7,
        unmeasuredCount: 0, duration: 1))

    guard case .completed(_, _, _, let completeness) = model.state else {
        Issue.record("expected .completed")
        return
    }
    #expect(completeness.unreadableDirectories == 7)
    #expect(!completeness.isExact)
}

@Test @MainActor func aStoppedFindReportsWhatItFoundRatherThanNothing() {
    let model = FinderViewModel()
    let file = FoundFile(
        path: URL(fileURLWithPath: "/tmp/a.bin"), sizeBytes: 4_096,
        lastModified: nil, isBundle: false)
    model.finish(FinderReport(
        files: [file], outcome: .cancelled, unreadableDirectoryCount: 0,
        unmeasuredCount: 0, duration: 1))

    guard case .cancelled(let items, let bytes, _) = model.state else {
        Issue.record("expected .cancelled")
        return
    }
    #expect(items == 1)
    #expect(bytes == 4_096)
}

/// `files` was `var` while `selectedFileIDs` was `private(set)`, so any writer
/// could replace the rows and leave ids selected that no longer match anything.
/// Harmless for removal, which filters through `files`; a count label would
/// over-report.
@Test @MainActor func replacingTheRowsDropsSelectionThatNoLongerMatches() {
    let model = FinderViewModel()
    let keep = FoundFile(path: URL(fileURLWithPath: "/tmp/keep.bin"),
                         sizeBytes: 1, lastModified: nil, isBundle: false)
    let drop = FoundFile(path: URL(fileURLWithPath: "/tmp/drop.bin"),
                         sizeBytes: 1, lastModified: nil, isBundle: false)
    model.replaceFiles([keep, drop])
    model.toggleSelection(keep.id)
    model.toggleSelection(drop.id)
    #expect(model.selectedFileIDs.count == 2)

    model.replaceFiles([keep])
    #expect(model.selectedFileIDs == [keep.id])
    #expect(model.selectedFiles.count == 1)
}

/// The row Toggle's setter discarded its incoming value and toggled instead.
/// Correct only while the getter is authoritative and every write is a real
/// change; a redundant write — which SwiftUI is free to make — flipped the row.
@Test @MainActor func settingARowsSelectionIsIdempotent() {
    let model = FinderViewModel()
    let file = FoundFile(path: URL(fileURLWithPath: "/tmp/a.bin"),
                         sizeBytes: 1, lastModified: nil, isBundle: false)
    model.replaceFiles([file])

    model.setSelection(file.id, isOn: true)
    model.setSelection(file.id, isOn: true)
    #expect(model.selectedFileIDs == [file.id])

    model.setSelection(file.id, isOn: false)
    model.setSelection(file.id, isOn: false)
    #expect(model.selectedFileIDs.isEmpty)
}

/// `setSelection`'s twin of `togglingAnUnknownIDSelectsNothing`: an id with
/// no matching row must not enter the selection just because the Binding
/// asked for `isOn: true`.
@Test @MainActor func settingAnUnknownIDToOnSelectsNothing() {
    let (model, _) = modelWithFiles(3)
    model.setSelection(UUID(), isOn: true)
    #expect(model.selectedFileIDs.isEmpty)
}

// MARK: - The sidebar's Files total

/// Nothing before a search. A "Zero KB" beside Files on launch would be a
/// measurement nobody took — the same class of claim the completeness marker
/// exists to keep honest.
@Test @MainActor func theFilesSidebarShowsNoTotalBeforeASearch() {
    #expect(FinderViewModel().sidebarTotalText == nil)
}

/// A "+" whenever a directory could not be read, matching what
/// `FoundFile.formattedSize` does for one row and the tray does for a whole
/// run. Without it the sidebar states a measured total for a run that was
/// refused part of the disk.
@Test @MainActor func theFilesSidebarTotalIsMarkedAsAFloorWhenAnythingWasUnreadable() {
    let model = FinderViewModel()
    let file = FoundFile(
        path: URL(fileURLWithPath: "/tmp/a.bin"), sizeBytes: 4_096,
        lastModified: nil, isBundle: false)

    model.finish(FinderReport(
        files: [file], outcome: .finished, unreadableDirectoryCount: 0,
        unmeasuredCount: 0, duration: 1))
    #expect(model.sidebarTotalText?.hasSuffix("+") == false)
    #expect(model.sidebarUnreadableText == nil)

    model.finish(FinderReport(
        files: [file], outcome: .finished, unreadableDirectoryCount: 3,
        unmeasuredCount: 0, duration: 1))
    #expect(model.sidebarTotalText?.hasSuffix("+") == true)
    #expect(model.sidebarUnreadableText == "3 folders unread")
}

/// Only the noun inflects, the same rule `unreadableMessage` follows.
@Test @MainActor func theFilesSidebarInflectsOneUnreadableFolder() {
    let model = FinderViewModel()
    model.finish(FinderReport(
        files: [], outcome: .finished, unreadableDirectoryCount: 1,
        unmeasuredCount: 0, duration: 1))
    #expect(model.sidebarUnreadableText == "1 folder unread")
}
