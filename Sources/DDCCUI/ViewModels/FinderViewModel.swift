import Foundation
import SwiftUI
import DDCCCore

/// State for the Files view.
///
/// Separate from `AppViewModel` rather than merged into it because the two scan
/// lifecycles are independent: a find must not disturb Caches results, and a
/// Caches scan must not disturb Files results.
@Observable
@MainActor
final class FinderViewModel {
    /// Only `replaceFiles` writes this. Paired with `private(set)` on
    /// `selectedFileIDs`: two collections that must agree cannot have one of
    /// them writable from outside.
    private(set) var files: [FoundFile] = []
    var state: ScanState = .idle
    /// Only `toggleSelection` and `setSelection` insert into this. There is
    /// no select-all, no tier toggle and no default: nothing vouches for
    /// these rows, so every one of them is chosen by hand.
    private(set) var selectedFileIDs: Set<UUID> = []
    var searchRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    var criteria: FinderCriteria = .defaults
    var searchText: String = ""
    private(set) var unreadableDirectoryCount = 0
    var lastDeletionReport: DeletionReport<FoundFile>?
    var showTrashConfirmation = false
    /// The root the most recent run actually walked, captured at `startFind`
    /// rather than read back from `searchRoot`. `searchRoot` is a live
    /// binding the toolbar's folder picker can change at any time, including
    /// after a run finishes and before Trash is pressed — without this,
    /// `moveSelectedToTrash` would build its `PathGuard.Context` from
    /// whatever the picker shows NOW, and every row from the OLD root would
    /// be refused as "outside the scan root" with no explanation, since
    /// nothing in this file's failure surface distinguishes that refusal
    /// from any other.
    private(set) var lastRunRoot: URL?

    private var finder: FileFinder?
    private var findTask: Task<Void, Never>?

    /// Test hook over `DeletionService.delete`, matching the precedent
    /// `DeletionService.FileOperations` already sets: a
    /// test can inject a report — succeeded rows, failed rows, or both —
    /// without touching the real filesystem. This default closure is the
    /// only place in this file `permanently:` appears, and it must stay
    /// `false`; the source-grep test enforces that.
    var deleteFiles: @Sendable ([FoundFile], PathGuard.Context) -> DeletionReport<FoundFile> =
        { files, context in DeletionService.delete(files, permanently: false, in: context) }

    var isRunning: Bool { findTask != nil }

    /// The selected file, but only if the list is still showing it. Same rule
    /// and same reason as `AppViewModel.visibleResult(id:)` — this view shared
    /// the defect, because its list renders `filteredFiles` while its pane
    /// resolved from `files`.
    func visibleFile(id: UUID?) -> FoundFile? {
        guard let id else { return nil }
        return filteredFiles.first { $0.id == id }
    }

    var filteredFiles: [FoundFile] {
        guard !searchText.isEmpty else { return files }
        return files.filter {
            $0.relativePath.localizedCaseInsensitiveContains(searchText)
                || $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedFiles: [FoundFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    var selectedSize: Int64 {
        selectedFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    /// What the sidebar shows beside the Files row, or `nil` before a
    /// search has run — a "Zero KB" on launch would be a measurement nobody
    /// took.
    ///
    /// A "+" marks the total as a floor whenever a directory could not be
    /// read — `Floor`, the same marker one row and a whole run carry. There
    /// is no "locked" figure to
    /// pair with it the way Caches has: every row this view produces can be
    /// moved to the Trash, so nothing here is withheld by privilege.
    var sidebarTotalText: String? {
        if case .idle = state { return nil }
        let base = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        return Floor.marked(base, exact: unreadableDirectoryCount == 0)
    }

    /// The count itself, phrased for the sidebar's second line. `nil` when
    /// nothing was refused, so the row stays one line in the common case.
    var sidebarUnreadableText: String? {
        guard unreadableDirectoryCount > 0 else { return nil }
        let noun = unreadableDirectoryCount == 1 ? "folder" : "folders"
        return "\(unreadableDirectoryCount) \(noun) unread"
    }

    var totalSize: Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }

    /// No count: both consumers already state one. The toolbar shows
    /// "N selected (SIZE)" immediately to the left of this button, and the
    /// sheet states the count, the size and every path.
    var trashButtonTitle: String { "Move Selected to Trash" }

    // MARK: - Actions

    func startFind() {
        guard findTask == nil else { return }

        replaceFiles([])
        unreadableDirectoryCount = 0
        // A stale failure banner outliving the run it described reports an
        // error about files that are no longer listed.
        lastDeletionReport = nil
        state = .scanning(currentPath: "Starting…", itemsFound: nil, bytesFound: nil)

        let root = searchRoot
        lastRunRoot = root
        let criteria = self.criteria
        let skipList = FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths)
        let guardContext = PathGuard.Context(
            scanRoot: root, declaredPaths: ScanProfile.declaredAbsolutePaths)

        // A fresh actor per run, for the same reason ScanCoordinator is
        // rebuilt per scan: cancel() is sticky, so a reused instance would
        // mean the first Stop press permanently broke every later Find.
        let finder = FileFinder()
        self.finder = finder
        findTask = Task { [weak self] in
            guard let self else { return }
            let report = await finder.run(
                root: root,
                criteria: criteria,
                skipList: skipList,
                guardContext: guardContext,
                onProgress: { path in
                    Task { @MainActor [weak self] in
                        self?.state = .scanning(
                            currentPath: PathDisplay.tildeAbbreviatedIfAbsolute(path),
                            itemsFound: nil, bytesFound: nil)
                    }
                }
            )
            await MainActor.run {
                self.finish(report)
                self.findTask = nil
                self.finder = nil
            }
        }
    }

    /// Internal, not private: a test drives this directly so the
    /// never-pre-selected property is checked on the path that actually
    /// produces rows, not only against a hand-assigned `files` array.
    func finish(_ report: FinderReport) {
        replaceFiles(report.files)
        unreadableDirectoryCount = report.unreadableDirectoryCount
        let bytes = report.files.reduce(0) { $0 + $1.sizeBytes }
        switch report.outcome {
        case .cancelled:
            state = .cancelled(
                itemsFound: report.files.count,
                bytesFound: bytes,
                completeness: report.completeness)
        case .finished:
            state = .completed(
                totalItems: report.files.count,
                totalBytes: bytes,
                duration: report.duration,
                completeness: report.completeness)
        }
    }

    func cancelFind() {
        findTask?.cancel()
        Task { [finder] in await finder?.cancel() }
    }

    /// The one way rows change. Drops any selected id the new rows do not
    /// contain, so a selection can never outlive what it pointed at.
    func replaceFiles(_ newFiles: [FoundFile]) {
        files = newFiles
        let live = Set(newFiles.map(\.id))
        selectedFileIDs.formIntersection(live)
    }

    func toggleSelection(_ id: UUID) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
            return
        }
        guard files.contains(where: { $0.id == id }) else { return }
        selectedFileIDs.insert(id)
    }

    /// Honours the value it is given rather than toggling. `toggleSelection`
    /// remains for the click gesture, where "the other one" is what the user
    /// means; a `Binding` setter is told what to become.
    func setSelection(_ id: UUID, isOn: Bool) {
        guard isOn else {
            selectedFileIDs.remove(id)
            return
        }
        guard files.contains(where: { $0.id == id }) else { return }
        selectedFileIDs.insert(id)
    }

    func deselectAll() {
        selectedFileIDs = []
    }

    /// Trash, never permanent removal. These rows are unaudited by
    /// construction, so a mistake must cost a restore rather than the file.
    func moveSelectedToTrash() {
        // `lastRunRoot`, not `searchRoot`: see that property's doc comment.
        let context = PathGuard.Context(
            scanRoot: lastRunRoot ?? searchRoot, declaredPaths: ScanProfile.declaredAbsolutePaths)
        let report = deleteFiles(selectedFiles, context)

        let removedIDs = Set(report.succeeded.map(\.id))
        replaceFiles(files.filter { !removedIDs.contains($0.id) })

        lastDeletionReport = report
        showTrashConfirmation = false
    }
}
