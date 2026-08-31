import Foundation
import SwiftUI
import DDCCCore

@Observable
@MainActor
final class AppViewModel {
    // MARK: - State
    var results: [ScanResult] = []
    /// Which view is showing. Changing it never touches either mode's
    /// results — a mode switch is a view change, not a reset.
    var mode: AppMode = .caches
    var scanState: ScanState = .idle
    var selectedCategory: CleanCategory? = nil
    var selectedResultIDs: Set<UUID> = []
    var searchText: String = ""
    var sortOrder: SortOrder = .sizeDescending
    var showDeleteConfirmation = false
    var scanPath: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Set after any deletion, so nothing is discarded silently.
    var lastDeletionReport: DeletionReport<ScanResult>?
    /// How the last deletion was attempted, in the words the notice uses.
    /// Captured when the deletion runs rather than derived from the
    /// confirmation sheet, whose toggle the user can change afterwards — the
    /// notice would then describe an operation that never happened.
    private(set) var lastDeletionOperation: String = "moved to the Trash"
    /// Seam over `DeletionService.delete`, matching the precedent
    /// `FinderViewModel.deleteFiles` sets for the same reason: a test can
    /// inject a report — succeeded rows, failed rows, or both — without
    /// touching the real filesystem. Unlike the Files seam this one carries
    /// `permanently`, because the Caches view genuinely offers both.
    var deleteResults: @Sendable ([ScanResult], Bool, PathGuard.Context)
        -> DeletionReport<ScanResult> =
        { results, permanently, context in
            DeletionService.delete(results, permanently: permanently, in: context)
        }
    var diskAccess: DiskAccessState = .unknown
    var diskAccessBannerDismissed = false
    private(set) var hasOpenedAccessSettings = false
    /// Cleared by `startScan()`. Approval lasts exactly one scan.
    private(set) var approval = ApprovalState()
    var pendingApproval: ApprovalPrompt?

    private let accessProbe: DiskAccessProbe

    init(accessProbe: DiskAccessProbe = DiskAccessProbe()) {
        self.accessProbe = accessProbe
    }

    // MARK: - Computed

    /// The selected row, but only if the list is still showing it.
    ///
    /// Resolved from `filteredResults`, never from `results`. Reading the
    /// unfiltered set while the list beside it renders the filtered one leaves
    /// the pane describing an item the list does not contain — every value in
    /// it correct, the frame as a whole false. The pane also carries Reveal in
    /// Finder and Open in Terminal, which would then act on a row the user
    /// cannot see.
    ///
    /// Returning `nil` rather than clearing `selectedResultID` on every filter
    /// change is the deliberate half: an empty pane is honest, and the user
    /// keeps their place when they clear the filter again.
    func visibleResult(id: UUID?) -> ScanResult? {
        guard let id else { return nil }
        return filteredResults.first { $0.id == id }
    }

    var filteredResults: [ScanResult] {
        var items = results

        if let category = selectedCategory {
            items = items.filter { $0.category == category }
        }

        if !searchText.isEmpty {
            items = items.filter {
                $0.relativePath.localizedCaseInsensitiveContains(searchText) ||
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOrder {
        case .sizeDescending:
            items.sort { $0.sizeBytes > $1.sizeBytes }
        case .sizeAscending:
            items.sort { $0.sizeBytes < $1.sizeBytes }
        case .nameAscending:
            items.sort { $0.relativePath < $1.relativePath }
        case .dateOldest:
            items.sort { ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture) }
        }

        return items
    }

    var categorySummary: [(category: CleanCategory, count: Int, totalSize: Int64, lockedSize: Int64)] {
        var summary: [CleanCategory: (count: Int, size: Int64, locked: Int64)] = [:]
        for result in results {
            let existing = summary[result.category] ?? (0, 0, 0)
            summary[result.category] = (
                existing.count + 1,
                existing.size + result.sizeBytes,
                existing.locked + (result.isDeletable ? 0 : result.sizeBytes)
            )
        }
        return CleanCategory.allCases.compactMap { category in
            guard let data = summary[category] else { return nil }
            return (category, data.count, data.size, data.locked)
        }.sorted {
            $0.totalSize == $1.totalSize
                ? $0.category.rawValue < $1.category.rawValue
                : $0.totalSize > $1.totalSize
        }
    }

    /// Bytes the app can never remove. Tier 2 and 3 are *gated*, not locked:
    /// they are reachable, and counting them here would tell the user their
    /// disk holds less recoverable space than it does.
    var lockedSize: Int64 {
        results.filter { !$0.isDeletable }.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalSize: Int64 {
        results.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedSize: Int64 {
        results.filter { selectedResultIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedResults: [ScanResult] {
        results.filter { selectedResultIDs.contains($0.id) }
    }

    /// The delete sheet's title. Here rather than in the sheet because a view's
    /// interpolated string is not reachable by any test, and this one read
    /// "Delete 1 items?" — which looks like a bug in the thing about to delete
    /// your files. Only the noun inflects.
    var deleteConfirmationTitle: String {
        let count = selectedResults.count
        return "Delete \(count) item\(count == 1 ? "" : "s")?"
    }

    /// Selected rows that are currently on screen, grouped in tier order and
    /// sorted largest first within each group. Empty tiers are omitted.
    var selectedVisibleByTier: [(tier: RemovalTier, results: [ScanResult])] {
        let visibleIDs = Set(filteredResults.map(\.id))
        let visible = selectedResults.filter { visibleIDs.contains($0.id) }
        return RemovalTier.allCases.compactMap { tier in
            let rows = visible.filter { $0.tier == tier }.inDisplayOrder()
            return rows.isEmpty ? nil : (tier, rows)
        }
    }

    /// Selected rows the current filter is hiding. Kept rather than cleared, and
    /// surfaced in the delete sheet so nothing is deleted unseen.
    var selectedHiddenResults: [ScanResult] {
        let visibleIDs = Set(filteredResults.map(\.id))
        return selectedResults
            .filter { !visibleIDs.contains($0.id) }
            .inDisplayOrder()
    }

    var selectionContainsDestructive: Bool {
        selectedResults.contains { $0.tier == .destructive }
    }

    var showsDiskAccessBanner: Bool {
        diskAccess == .denied && !diskAccessBannerDismissed
    }

    /// macOS sometimes needs a relaunch before a new grant takes effect. Only
    /// say so once the user has actually been to Settings, or it reads as noise.
    var suggestsRelaunch: Bool {
        diskAccess == .denied && hasOpenedAccessSettings
    }

    // MARK: - Actions

    // A fresh `ScanCoordinator` per scan: `cancel()` is sticky on the actor,
    // so reusing one instance would let the first Stop press permanently
    // break every Scan press after it. `cancelScan()` reads whichever
    // coordinator is current, so it always targets the run actually in flight.
    private var coordinator: ScanCoordinator?
    private var scanTask: Task<Void, Never>?

    var isScanRunning: Bool { scanTask != nil }

    func startScan() {
        // Guard: a second concurrent scan would append into the same array
        // and leak the first task.
        guard scanTask == nil else { return }

        results = []
        selectedResultIDs = []
        // A stale failure banner outliving the run it described reports an
        // error about rows that are no longer listed.
        lastDeletionReport = nil
        approval.clear()
        pendingApproval = nil
        scanState = .scanning(currentPath: "Starting…", itemsFound: nil, bytesFound: nil)

        let root = scanPath
        let coordinator = ScanCoordinator()
        self.coordinator = coordinator
        scanTask = Task { [weak self] in
            guard let self else { return }
            let report = await coordinator.run(
                root: root,
                onPhase: { phase in
                    Task { @MainActor [weak self] in self?.apply(phase) }
                }
            )
            await MainActor.run {
                self.finish(report)
                self.scanTask = nil
                self.coordinator = nil
            }
        }
    }

    @MainActor
    private func apply(_ phase: ScanPhase) {
        switch phase {
        case .discovering(let path):
            scanState = .scanning(
                currentPath: PathDisplay.tildeAbbreviatedIfAbsolute(path), itemsFound: nil, bytesFound: nil)
        case .resolving:
            scanState = .scanning(
                currentPath: "Resolving overlaps…", itemsFound: nil, bytesFound: nil)
        case .measuring(let progress):
            scanState = .measuring(progress: progress)
        }
    }

    /// Terminal state comes from the report's outcome — never set
    /// independently, which is how a cancelled scan could end up reporting
    /// as finished.
    ///
    /// Internal, not private: a test drives this directly.
    @MainActor
    func finish(_ report: ScanReport) {
        results = report.results
        let bytes = report.results.reduce(0) { $0 + $1.sizeBytes }
        switch report.outcome {
        case .cancelled:
            scanState = .cancelled(
                itemsFound: report.results.count,
                bytesFound: bytes,
                completeness: report.completeness)
        case .finished:
            scanState = .completed(
                totalItems: report.results.count,
                totalBytes: bytes,
                duration: report.duration,
                completeness: report.completeness)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        Task { await coordinator?.cancel() }
    }

    /// The ids a tier toggle may add, scoped to what the user can currently see.
    func eligibleIDs(forTier tier: RemovalTier) -> Set<UUID> {
        SelectionPolicy.bulkSelectableIDs(from: filteredResults, given: approval, tier: tier)
    }

    /// Derived, never stored, so the control can never disagree with the list.
    /// An empty eligible set is NOT "fully selected" — vacuous truth would light
    /// the toggle before a scan has produced anything to select.
    func isTierFullySelected(_ tier: RemovalTier) -> Bool {
        let eligible = eligibleIDs(forTier: tier)
        return !eligible.isEmpty && eligible.isSubset(of: selectedResultIDs)
    }

    /// Unions and subtracts rather than replacing, so a hand-picked tier 3 item
    /// survives a tier 1 toggle.
    func setTier(_ tier: RemovalTier, selected: Bool) {
        let eligible = eligibleIDs(forTier: tier)
        if selected {
            selectedResultIDs.formUnion(eligible)
        } else {
            selectedResultIDs.subtract(eligible)
        }
    }

    /// Costly categories on screen that could be acknowledged but have not been.
    /// Excludes rows that require privileges: those can never be unlocked, so
    /// counting them would promise the user something acknowledgement cannot do.
    var gatedCostlyCategories: Set<CleanCategory> {
        Set(
            filteredResults.lazy
                .filter {
                    $0.tier == .costly && $0.isDeletable
                        && !self.approval.acknowledgedCategories.contains($0.category)
                }
                .map(\.category)
        )
    }

    /// The Tier 2 toggle. Turning it ON with categories still gated raises a bulk
    /// acknowledgement rather than silently doing nothing. Turning it OFF never
    /// prompts — withdrawing a selection needs no approval.
    func setCostlyTier(selected: Bool) {
        guard selected else {
            setTier(.costly, selected: false)
            return
        }
        let gated = gatedCostlyCategories
        guard !gated.isEmpty else {
            setTier(.costly, selected: true)
            return
        }
        pendingApproval = .costlyCategories(gated.sorted { $0.rawValue < $1.rawValue })
    }

    /// Costly rows in view that the app could remove, gated or not. The Tier 2
    /// control is disabled only when there are none — being gated is now a reason
    /// to prompt, not a reason to be inert.
    var visibleCostlyRowCount: Int {
        filteredResults.filter { $0.tier == .costly && $0.isDeletable }.count
    }

    func deselectAll() {
        selectedResultIDs = []
    }

    func toggleSelection(_ id: UUID) {
        // Deselection is unconditional and checked FIRST. Selectability gates
        // what may be added; gating removal too would strand a selection the
        // user cannot clear once approval becomes mutable.
        if selectedResultIDs.contains(id) {
            selectedResultIDs.remove(id)
            return
        }
        guard let result = results.first(where: { $0.id == id }) else { return }

        switch SelectionPolicy.selectability(of: result, given: approval) {
        case .selectable:
            selectedResultIDs.insert(id)
        case .needsCategoryAcknowledgement(let category):
            pendingApproval = .category(category, triggeredBy: id)
        case .needsItemOptIn:
            pendingApproval = .item(id)
        case .lockedRequiresPrivileges:
            break   // nothing to approve; the row is inert
        }
    }

    func confirmPendingApproval() {
        guard let prompt = pendingApproval else { return }
        pendingApproval = nil
        switch prompt {
        case .category(let category, let triggeredBy):
            approval.acknowledge(category)
            select(triggeredBy)
        case .item(let id):
            approval.optIn(id)
            select(id)
        case .costlyCategories(let categories):
            for category in categories { approval.acknowledge(category) }
            setTier(.costly, selected: true)
        }
    }

    /// Every insertion into the selection goes through the policy. Recording an
    /// approval is not the same as proving the row still exists and is selectable,
    /// and this is the last place that distinction was taken on trust.
    private func select(_ id: UUID) {
        guard let result = results.first(where: { $0.id == id }),
              SelectionPolicy.selectability(of: result, given: approval) == .selectable
        else { return }
        selectedResultIDs.insert(id)
    }

    func cancelPendingApproval() {
        pendingApproval = nil
    }

    func deleteSelected(permanently: Bool = false) {
        let context = PathGuard.Context(
            scanRoot: scanPath, declaredPaths: ScanProfile.declaredAbsolutePaths)
        let report = deleteResults(selectedResults, permanently, context)

        let removedIDs = Set(report.succeeded.map(\.id))
        results.removeAll { removedIDs.contains($0.id) }
        // Failed rows stay selected deliberately, so the user can retry them.
        // That is only defensible because the notice now says why they are
        // still there; without it, they read as a delete that did nothing.
        selectedResultIDs.subtract(removedIDs)

        lastDeletionOperation = permanently ? "deleted permanently" : "moved to the Trash"
        lastDeletionReport = report
        showDeleteConfirmation = false
    }

    func refreshDiskAccess() {
        diskAccess = accessProbe.state()
    }

    func markOpenedAccessSettings() {
        hasOpenedAccessSettings = true
    }

    enum SortOrder: String, CaseIterable {
        case sizeDescending = "Largest First"
        case sizeAscending = "Smallest First"
        case nameAscending = "Name"
        case dateOldest = "Oldest First"
    }

    /// A pending approval the UI must present before a selection can be made.
    /// `Identifiable` so views can drive `.sheet(item:)` from it.
    enum ApprovalPrompt: Equatable, Identifiable {
        case category(CleanCategory, triggeredBy: UUID)
        case item(UUID)
        /// Raised by the Tier 2 toggle when costly categories are still gated.
        /// Confirming acknowledges all of them, which is why the sheet lists
        /// every one with its cost.
        case costlyCategories([CleanCategory])

        var id: String {
            switch self {
            case .category(let category, let triggeredBy):
                return "category-\(category.rawValue)-\(triggeredBy.uuidString)"
            case .item(let id):
                return "item-\(id.uuidString)"
            case .costlyCategories(let categories):
                return "costly-" + categories.map(\.rawValue).joined(separator: ",")
            }
        }
    }
}
