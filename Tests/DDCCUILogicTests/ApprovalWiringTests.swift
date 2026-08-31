import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

private func result(
    tier: RemovalTier,
    category: CleanCategory = .nodeJS,
    isDeletable: Bool = true,
    sizeBytes: Int64 = 4096,
    path: URL = URL(fileURLWithPath: "/tmp/ddcc-\(UUID().uuidString)")
) -> ScanResult {
    ScanResult(
        path: path,
        category: category, tier: tier, removability: .removable,
        sizeBytes: sizeBytes, lastModified: nil, displayName: "x",
        partialRead: false, unreadablePaths: [], isDeletable: isDeletable
    )
}

@MainActor
private func viewModel(_ results: [ScanResult]) -> AppViewModel {
    let model = AppViewModel()
    model.results = results
    return model
}

// MARK: - Prompts

@Test @MainActor func clickingACostlyRowRaisesACategoryPromptAndSelectsNothing() {
    let costly = result(tier: .costly, category: .python)
    let model = viewModel([costly])

    model.toggleSelection(costly.id)

    #expect(model.pendingApproval == .category(.python, triggeredBy: costly.id))
    #expect(model.selectedResultIDs.isEmpty)
}

@Test @MainActor func clickingADestructiveRowRaisesAnItemPromptAndSelectsNothing() {
    let destructive = result(tier: .destructive)
    let model = viewModel([destructive])

    model.toggleSelection(destructive.id)

    #expect(model.pendingApproval == .item(destructive.id))
    #expect(model.selectedResultIDs.isEmpty)
}

@Test @MainActor func clickingALockedRowRaisesNothing() {
    let locked = result(tier: .safe, isDeletable: false)
    let model = viewModel([locked])

    model.toggleSelection(locked.id)

    #expect(model.pendingApproval == nil)
    #expect(model.selectedResultIDs.isEmpty)
}

@Test @MainActor func confirmingACategoryPromptAcknowledgesAndSelectsTheTriggeringRow() {
    let a = result(tier: .costly, category: .python)
    let b = result(tier: .costly, category: .python)
    let model = viewModel([a, b])
    model.toggleSelection(a.id)

    model.confirmPendingApproval()

    #expect(model.approval.acknowledgedCategories == [.python])
    #expect(model.selectedResultIDs == [a.id], "only the row that raised the prompt is selected")
    #expect(model.pendingApproval == nil)
}

@Test @MainActor func confirmingAnItemPromptOptsInOnlyThatItem() {
    let a = result(tier: .destructive)
    let b = result(tier: .destructive)
    let model = viewModel([a, b])
    model.toggleSelection(a.id)

    model.confirmPendingApproval()

    #expect(model.approval.optedInItems == [a.id])
    #expect(model.selectedResultIDs == [a.id])
}

@Test @MainActor func cancellingAPromptApprovesNothing() {
    let costly = result(tier: .costly, category: .python)
    let model = viewModel([costly])
    model.toggleSelection(costly.id)

    model.cancelPendingApproval()

    #expect(model.approval.acknowledgedCategories.isEmpty)
    #expect(model.selectedResultIDs.isEmpty)
    #expect(model.pendingApproval == nil)
}

@Test @MainActor func anAcknowledgedCategorySelectsDirectlyWithoutAPrompt() {
    let a = result(tier: .costly, category: .python)
    let b = result(tier: .costly, category: .python)
    let model = viewModel([a, b])
    model.toggleSelection(a.id)
    model.confirmPendingApproval()

    model.toggleSelection(b.id)

    #expect(model.pendingApproval == nil, "the category is already acknowledged")
    #expect(model.selectedResultIDs == [a.id, b.id])
}

// MARK: - Per-scan approval

/// Per-scan approval is the design's headline decision, and it rests on one line
/// in startScan(). acknowledgedCategories is keyed by category, so without the
/// clear it survives into a scan of different files.
@Test @MainActor func startScanClearsApprovalAndAnyPendingPrompt() {
    let costly = result(tier: .costly, category: .python)
    let other = result(tier: .costly, category: .rust)
    let model = viewModel([costly, other])
    model.toggleSelection(costly.id)
    model.confirmPendingApproval()
    model.toggleSelection(other.id)          // leaves a prompt pending

    #expect(model.approval.acknowledgedCategories == [.python])
    #expect(model.pendingApproval != nil)

    model.scanPath = URL(fileURLWithPath: NSTemporaryDirectory())
    model.startScan()
    model.cancelScan()                        // do not leave a scan running

    #expect(model.approval.acknowledgedCategories.isEmpty)
    #expect(model.approval.optedInItems.isEmpty)
    #expect(model.pendingApproval == nil)
}

// MARK: - Deselection stays unconditional

/// Carry-forward #2. Selectability gates what may be ADDED, never what may be
/// removed. This is now reachable: a row can be selected and then lose its
/// approval when a new scan clears it.
@Test @MainActor func deselectionIsNeverRefusedForAGatedRow() {
    let costly = result(tier: .costly, category: .python)
    let model = viewModel([costly])
    model.selectedResultIDs = [costly.id]

    model.toggleSelection(costly.id)

    #expect(model.selectedResultIDs.isEmpty)
    #expect(model.pendingApproval == nil, "deselecting must not raise an approval prompt")
}

// MARK: - Tier toggles

@Test @MainActor func selectingTierOneLeavesOtherTiersAlone() {
    let safe = result(tier: .safe)
    let costly = result(tier: .costly, category: .python)
    let destructive = result(tier: .destructive)
    let model = viewModel([safe, costly, destructive])
    model.toggleSelection(destructive.id)
    model.confirmPendingApproval()          // hand-picked tier 3

    model.setTier(.safe, selected: true)

    #expect(model.selectedResultIDs == [safe.id, destructive.id])
}

@Test @MainActor func deselectingTierOneLeavesOtherTiersAlone() {
    let safe = result(tier: .safe)
    let destructive = result(tier: .destructive)
    let model = viewModel([safe, destructive])
    model.toggleSelection(destructive.id)
    model.confirmPendingApproval()
    model.setTier(.safe, selected: true)

    model.setTier(.safe, selected: false)

    #expect(model.selectedResultIDs == [destructive.id])
}

@Test @MainActor func tierTwoReachesOnlyAcknowledgedCategories() {
    let python = result(tier: .costly, category: .python)
    let rust = result(tier: .costly, category: .rust)
    let model = viewModel([python, rust])
    model.toggleSelection(python.id)
    model.confirmPendingApproval()          // acknowledges .python, and selects it
    model.deselectAll()                     // so the toggle must do the work, not the confirm

    model.setTier(.costly, selected: true)

    #expect(model.selectedResultIDs == [python.id])
}

/// The confirm step selects only the row that raised the prompt. The toggle is
/// what reaches the rest of an acknowledged category.
@Test @MainActor func tierTwoSelectsUntouchedRowsInAnAcknowledgedCategory() {
    let a = result(tier: .costly, category: .python)
    let b = result(tier: .costly, category: .python)
    let model = viewModel([a, b])
    model.toggleSelection(a.id)
    model.confirmPendingApproval()

    model.setTier(.costly, selected: true)

    #expect(model.selectedResultIDs == [a.id, b.id], "b was never clicked; the toggle reached it")
}

/// The view-model half of the load-bearing property. The row must be OPTED IN —
/// and therefore `.selectable` — or the generic filter excludes it and the tier-3
/// guard is never what the test is exercising.
@Test @MainActor func noTierToggleCanSelectADestructiveRowEvenWhenOptedIn() {
    let destructive = result(tier: .destructive)
    let model = viewModel([destructive])
    model.toggleSelection(destructive.id)
    model.confirmPendingApproval()           // opted in, so now .selectable
    model.deselectAll()                      // so the toggle must do the work

    model.setTier(.destructive, selected: true)
    model.setTier(.safe, selected: true)
    model.setTier(.costly, selected: true)

    #expect(model.selectedResultIDs.isEmpty, "no toggle may reach tier 3, opted in or not")
}

@Test @MainActor func tierIsFullySelectedOnlyWhenEveryEligibleRowIsSelected() {
    let a = result(tier: .safe)
    let b = result(tier: .safe)
    let model = viewModel([a, b])

    #expect(model.isTierFullySelected(.safe) == false)
    model.setTier(.safe, selected: true)
    #expect(model.isTierFullySelected(.safe))
    model.toggleSelection(b.id)             // hand-deselect one
    #expect(model.isTierFullySelected(.safe) == false)
}

/// Vacuous truth would light the toggle before any scan has run.
@Test @MainActor func anEmptyEligibleSetIsNotFullySelected() {
    let model = viewModel([])
    #expect(model.isTierFullySelected(.safe) == false)
    #expect(model.eligibleIDs(forTier: .safe).isEmpty)
}

@Test @MainActor func tierTogglesActOnlyOnVisibleRows() {
    let visible = result(tier: .safe, category: .nodeJS)
    let hidden = result(tier: .safe, category: .rust)
    let model = viewModel([visible, hidden])
    model.selectedCategory = .nodeJS

    model.setTier(.safe, selected: true)

    #expect(model.selectedResultIDs == [visible.id])
}

@Test @MainActor func gatedCostlyCategoriesListsOnlyUnacknowledgedOnes() {
    let python = result(tier: .costly, category: .python)
    let rust = result(tier: .costly, category: .rust)
    let locked = result(tier: .costly, category: .xcode, isDeletable: false)
    let model = viewModel([python, rust, locked])

    #expect(model.gatedCostlyCategories == [.python, .rust],
            "a category that can never be unlocked is not 'gated'")

    model.toggleSelection(python.id)
    model.confirmPendingApproval()
    #expect(model.gatedCostlyCategories == [.rust])
}

// MARK: - Delete sheet grouping

@Test @MainActor func selectionGroupsByTierLargestFirst() {
    let small = result(tier: .safe, sizeBytes: 100)
    let large = result(tier: .safe, sizeBytes: 900)
    let costly = result(tier: .costly, category: .python)
    let model = viewModel([small, large, costly])
    model.toggleSelection(costly.id)
    model.confirmPendingApproval()
    model.setTier(.safe, selected: true)

    let groups = model.selectedVisibleByTier

    #expect(groups.map(\.tier) == [.safe, .costly], "tier order, and empty tiers omitted")
    #expect(groups[0].results.map(\.id) == [large.id, small.id], "largest first within a group")
}

@Test @MainActor func rowsHiddenByTheFilterAreSeparatedOut() {
    let visible = result(tier: .safe, category: .nodeJS)
    let hidden = result(tier: .safe, category: .rust)
    let model = viewModel([visible, hidden])
    model.setTier(.safe, selected: true)     // both visible, both selected
    model.selectedCategory = .nodeJS         // now one is hidden

    #expect(model.selectedVisibleByTier.flatMap(\.results).map(\.id) == [visible.id])
    #expect(model.selectedHiddenResults.map(\.id) == [hidden.id])
}

@Test @MainActor func destructiveSelectionIsFlaggedForTheTypedConfirmation() {
    let safe = result(tier: .safe)
    let destructive = result(tier: .destructive)
    let model = viewModel([safe, destructive])

    model.setTier(.safe, selected: true)
    #expect(model.selectionContainsDestructive == false)

    model.toggleSelection(destructive.id)
    model.confirmPendingApproval()
    #expect(model.selectionContainsDestructive)
}

/// Nothing may be deleted without appearing in the sheet. The two groupings must
/// partition the selection exactly — no row in neither, none in both.
@Test @MainActor func everySelectedRowAppearsExactlyOnceInTheDeleteSheetGroups() {
    let visibleSafe = result(tier: .safe, category: .nodeJS)
    let visibleCostly = result(tier: .costly, category: .nodeJS)
    let hiddenSafe = result(tier: .safe, category: .rust)
    let model = viewModel([visibleSafe, visibleCostly, hiddenSafe])
    model.toggleSelection(visibleCostly.id)
    model.confirmPendingApproval()
    model.setTier(.safe, selected: true)     // selects both safe rows, all still visible
    model.selectedCategory = .nodeJS          // now hiddenSafe is out of view

    let shown = model.selectedVisibleByTier.flatMap(\.results).map(\.id)
        + model.selectedHiddenResults.map(\.id)

    #expect(Set(shown) == model.selectedResultIDs, "every selected row is shown")
    #expect(shown.count == model.selectedResultIDs.count, "and none is shown twice")
}

// MARK: - Locked subtotals

@Test @MainActor func lockedSizeCountsOnlyRowsThatCanNeverBeRemoved() {
    let removable = result(tier: .safe, sizeBytes: 100)
    let gatedCostly = result(tier: .costly, category: .python, sizeBytes: 200)
    let gatedDestructive = result(tier: .destructive, sizeBytes: 400)
    let locked = result(tier: .safe, isDeletable: false, sizeBytes: 800)
    let model = viewModel([removable, gatedCostly, gatedDestructive, locked])

    #expect(model.lockedSize == 800,
            "gated is not locked — tier 2 and 3 are reachable, privileges are not")
}

// MARK: - Tier 2 bulk acknowledgement

@Test @MainActor func tierTwoToggleRaisesABulkPromptWhenCategoriesAreGated() {
    let python = result(tier: .costly, category: .python)
    let rust = result(tier: .costly, category: .rust)
    let model = viewModel([python, rust])

    model.setCostlyTier(selected: true)

    #expect(model.pendingApproval == .costlyCategories([.python, .rust]))
    #expect(model.selectedResultIDs.isEmpty, "nothing is selected until the user confirms")
}

@Test @MainActor func confirmingTheBulkPromptEnablesEveryListedCategoryAndSelects() {
    let python = result(tier: .costly, category: .python)
    let rust = result(tier: .costly, category: .rust)
    let model = viewModel([python, rust])
    model.setCostlyTier(selected: true)

    model.confirmPendingApproval()

    #expect(model.approval.acknowledgedCategories == [.python, .rust])
    #expect(model.selectedResultIDs == [python.id, rust.id])
}

@Test @MainActor func cancellingTheBulkPromptEnablesNothing() {
    let python = result(tier: .costly, category: .python)
    let model = viewModel([python])
    model.setCostlyTier(selected: true)

    model.cancelPendingApproval()

    #expect(model.approval.acknowledgedCategories.isEmpty)
    #expect(model.selectedResultIDs.isEmpty)
}

/// Withdrawing a selection needs no approval, so OFF must never raise a sheet —
/// including while categories are still gated, which is when ON would.
@Test @MainActor func turningTierTwoOffNeverPromptsEvenWhileCategoriesAreGated() {
    let python = result(tier: .costly, category: .python)
    let model = viewModel([python])
    #expect(model.gatedCostlyCategories == [.python], "gated, so ON would prompt here")

    model.setCostlyTier(selected: false)

    #expect(model.pendingApproval == nil)
    #expect(model.selectedResultIDs.isEmpty)
}

/// The mechanism this revision exists for: gated is a reason to PROMPT, not a
/// reason to be inert. Reverting this to the eligible-set check would restore the
/// dead control the change was made to remove.
@Test @MainActor func tierTwoStaysAvailableWhileCategoriesAreGated() {
    let costly = result(tier: .costly, category: .python)
    let model = viewModel([costly])

    #expect(model.eligibleIDs(forTier: .costly).isEmpty, "nothing acknowledged yet")
    #expect(model.visibleCostlyRowCount == 1, "but the control must stay live to prompt")
}

@Test @MainActor func tierTwoIsUnavailableWhenNoCostlyRowsAreInView() {
    let model = viewModel([result(tier: .safe)])
    #expect(model.visibleCostlyRowCount == 0)
}

@Test @MainActor func visibleCostlyRowCountSkipsHiddenAndUnremovableRows() {
    let visible = result(tier: .costly, category: .python)
    let hidden = result(tier: .costly, category: .rust)
    let locked = result(tier: .costly, category: .python, isDeletable: false)
    let model = viewModel([visible, hidden, locked])
    model.selectedCategory = .python

    #expect(model.visibleCostlyRowCount == 1, "hidden by filter, and locked, both excluded")
}

@Test @MainActor func tierTwoSelectsDirectlyWhenNothingIsGated() {
    let python = result(tier: .costly, category: .python)
    let model = viewModel([python])
    model.setCostlyTier(selected: true)
    model.confirmPendingApproval()
    model.deselectAll()

    model.setCostlyTier(selected: true)

    #expect(model.pendingApproval == nil, "already acknowledged, so no sheet")
    #expect(model.selectedResultIDs == [python.id])
}

/// Equal-sized rows reordering between runs makes the delete sheet look like it
/// changed when nothing did. Size descending stays the primary order within a
/// tier group; path breaks ties.
@Test @MainActor func selectedVisibleByTierOrdersEqualSizedRowsByPath() {
    let c = result(tier: .safe, sizeBytes: 500, path: URL(fileURLWithPath: "/tmp/c.bin"))
    let a = result(tier: .safe, sizeBytes: 500, path: URL(fileURLWithPath: "/tmp/a.bin"))
    let b = result(tier: .safe, sizeBytes: 500, path: URL(fileURLWithPath: "/tmp/b.bin"))
    let model = viewModel([c, a, b])
    model.setTier(.safe, selected: true)

    let rows = model.selectedVisibleByTier.first { $0.tier == .safe }?.results ?? []

    #expect(rows.map(\.path.lastPathComponent) == ["a.bin", "b.bin", "c.bin"])
}

/// Same tie-break, for the rows the delete sheet lists as hidden-by-filter.
@Test @MainActor func selectedHiddenResultsOrdersEqualSizedRowsByPath() {
    let c = result(tier: .safe, category: .rust, sizeBytes: 500, path: URL(fileURLWithPath: "/tmp/c.bin"))
    let a = result(tier: .safe, category: .rust, sizeBytes: 500, path: URL(fileURLWithPath: "/tmp/a.bin"))
    let b = result(tier: .safe, category: .rust, sizeBytes: 500, path: URL(fileURLWithPath: "/tmp/b.bin"))
    let model = viewModel([c, a, b])
    model.setTier(.safe, selected: true)
    model.selectedCategory = .nodeJS   // hides all three: their category is .rust

    #expect(model.selectedHiddenResults.map(\.path.lastPathComponent) == ["a.bin", "b.bin", "c.bin"])
}

/// The `:78` sort works on tuples, not `ScanResult`, so it needs its own explicit
/// tie-break rather than the shared comparator. Equal totals order by category name.
/// `.rust` and `.javaKotlin` are chosen deliberately: `.rust` comes first in
/// `CleanCategory.allCases` declaration order, but "Java/Kotlin" sorts before
/// "Rust" alphabetically — so a test relying on cases whose declaration order
/// already matches alphabetical order (e.g. `.nodeJS`/`.rust`) would pass by
/// coincidence even without the tie-break.
@Test @MainActor func categorySummaryOrdersEqualTotalsByCategoryName() {
    let rust = result(tier: .safe, category: .rust, sizeBytes: 500)
    let java = result(tier: .safe, category: .javaKotlin, sizeBytes: 500)
    let model = viewModel([rust, java])

    #expect(
        model.categorySummary.map(\.category) == [.javaKotlin, .rust],
        "\"Java/Kotlin\" < \"Rust\", opposite of allCases declaration order")
}

@Test @MainActor func categorySummaryReportsLockedBytesPerCategory() {
    let open = result(tier: .safe, category: .nodeJS, sizeBytes: 100)
    let locked = result(tier: .safe, category: .nodeJS, isDeletable: false, sizeBytes: 300)
    let lockedTwo = result(tier: .safe, category: .nodeJS, isDeletable: false, sizeBytes: 500)
    let other = result(tier: .safe, category: .rust, sizeBytes: 50)
    let model = viewModel([open, locked, lockedTwo, other])

    let node = model.categorySummary.first { $0.category == .nodeJS }
    let rust = model.categorySummary.first { $0.category == .rust }

    #expect(node?.totalSize == 900)
    #expect(node?.lockedSize == 800)
    #expect(rust?.lockedSize == 0)
}
