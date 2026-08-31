import Testing
import Foundation
@testable import DDCCCore

private func result(
    tier: RemovalTier,
    category: CleanCategory = .nodeJS,
    isDeletable: Bool = true,
    sizeBytes: Int64 = 4096
) -> ScanResult {
    ScanResult(
        path: URL(fileURLWithPath: "/tmp/x-\(UUID().uuidString)"),
        category: category, tier: tier, removability: .removable,
        sizeBytes: sizeBytes, lastModified: nil, displayName: "x",
        partialRead: false, unreadablePaths: [], isDeletable: isDeletable
    )
}

private func approval(
    categories: Set<CleanCategory> = [], items: Set<UUID> = []
) -> ApprovalState {
    var state = ApprovalState()
    for category in categories { state.acknowledge(category) }
    for item in items { state.optIn(item) }
    return state
}

// MARK: - Verdicts

@Test func safeRowsAreSelectable() {
    #expect(SelectionPolicy.selectability(of: result(tier: .safe), given: approval()) == .selectable)
}

@Test func costlyRowsNeedTheirCategoryAcknowledged() {
    let row = result(tier: .costly, category: .python)
    #expect(SelectionPolicy.selectability(of: row, given: approval())
            == .needsCategoryAcknowledgement(.python))
    #expect(SelectionPolicy.selectability(of: row, given: approval(categories: [.python]))
            == .selectable)
}

/// Acknowledging one category must not unlock another.
@Test func acknowledgementIsScopedToItsOwnCategory() {
    let row = result(tier: .costly, category: .python)
    #expect(SelectionPolicy.selectability(of: row, given: approval(categories: [.rust]))
            == .needsCategoryAcknowledgement(.python))
}

@Test func destructiveRowsNeedAPerItemOptIn() {
    let row = result(tier: .destructive)
    #expect(SelectionPolicy.selectability(of: row, given: approval()) == .needsItemOptIn)
    #expect(SelectionPolicy.selectability(of: row, given: approval(items: [row.id])) == .selectable)
}

/// Opting one item in must not opt its neighbours in.
@Test func optInIsScopedToItsOwnItem() {
    let a = result(tier: .destructive)
    let b = result(tier: .destructive)
    #expect(SelectionPolicy.selectability(of: b, given: approval(items: [a.id])) == .needsItemOptIn)
}

// MARK: - isDeletable beats tier

/// The ordering IS the property: no amount of approval unlocks a row the app
/// cannot remove, at any tier.
@Test func notDeletableBeatsEveryTierAndEveryApproval() {
    let safe = result(tier: .safe, isDeletable: false)
    let costly = result(tier: .costly, category: .python, isDeletable: false)
    let destructive = result(tier: .destructive, isDeletable: false)

    #expect(SelectionPolicy.selectability(of: safe, given: approval()) == .lockedRequiresPrivileges)
    #expect(SelectionPolicy.selectability(of: costly, given: approval(categories: [.python]))
            == .lockedRequiresPrivileges)
    #expect(SelectionPolicy.selectability(of: destructive, given: approval(items: [destructive.id]))
            == .lockedRequiresPrivileges)
}

// MARK: - Bulk selection

@Test func bulkSelectionReturnsOnlyTheRequestedTier() {
    let safe = result(tier: .safe)
    let costly = result(tier: .costly, category: .python)
    let state = approval(categories: [.python])

    #expect(SelectionPolicy.bulkSelectableIDs(from: [safe, costly], given: state, tier: .safe)
            == [safe.id])
    #expect(SelectionPolicy.bulkSelectableIDs(from: [safe, costly], given: state, tier: .costly)
            == [costly.id])
}

@Test func bulkSelectionSkipsUnacknowledgedCostlyRows() {
    let costly = result(tier: .costly, category: .python)
    #expect(SelectionPolicy.bulkSelectableIDs(from: [costly], given: approval(), tier: .costly)
            .isEmpty)
}

@Test func bulkSelectionSkipsRowsThatRequirePrivileges() {
    let locked = result(tier: .safe, isDeletable: false)
    #expect(SelectionPolicy.bulkSelectableIDs(from: [locked], given: approval(), tier: .safe)
            .isEmpty)
}

/// THE load-bearing test. An opted-in destructive row IS `.selectable`, so a
/// bulk predicate that filtered on selectability alone would sweep it up. No
/// bulk facility may ever reach tier 3.
@Test func bulkSelectionNeverReturnsDestructiveRowsEvenWhenOptedIn() {
    let destructive = result(tier: .destructive)
    let state = approval(items: [destructive.id])

    #expect(SelectionPolicy.selectability(of: destructive, given: state) == .selectable)
    #expect(SelectionPolicy.bulkSelectableIDs(from: [destructive], given: state, tier: .destructive)
            .isEmpty)
}

@Test func bulkSelectionOfEmptyInputIsEmpty() {
    #expect(SelectionPolicy.bulkSelectableIDs(from: [], given: approval(), tier: .safe).isEmpty)
}

// MARK: - ApprovalState

@Test func clearResetsBothSets() {
    let row = result(tier: .destructive)
    var state = approval(categories: [.python], items: [row.id])
    state.clear()
    #expect(state.acknowledgedCategories.isEmpty)
    #expect(state.optedInItems.isEmpty)
}
