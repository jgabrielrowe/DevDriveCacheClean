import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

private func result(tier: RemovalTier, category: CleanCategory = .nodeJS, isDeletable: Bool = true) -> ScanResult {
    ScanResult(
        path: URL(fileURLWithPath: "/tmp/ddcc-\(UUID().uuidString)"),
        category: category, tier: tier, removability: .removable,
        sizeBytes: 4096, lastModified: nil, displayName: "x",
        partialRead: false, unreadablePaths: [], isDeletable: isDeletable
    )
}

@MainActor
private func viewModel(_ results: [ScanResult]) -> AppViewModel {
    let model = AppViewModel()
    model.results = results
    return model
}

@Test @MainActor func selectingAnUnselectableRowIsRefused() {
    let costly = result(tier: .costly)
    let model = viewModel([costly])

    model.toggleSelection(costly.id)

    #expect(model.selectedResultIDs.isEmpty)
}

@Test @MainActor func selectingASelectableRowWorks() {
    let safe = result(tier: .safe)
    let model = viewModel([safe])

    model.toggleSelection(safe.id)

    #expect(model.selectedResultIDs == [safe.id])
}

/// Graduated approval makes selectability mutable, so a row can be selected
/// and then become unselectable. Deselection must never
/// be refused, or the user is left with a selection they cannot clear.
@Test @MainActor func deselectionIsNeverRefused() {
    let costly = result(tier: .costly)
    let model = viewModel([costly])
    model.selectedResultIDs = [costly.id]

    model.toggleSelection(costly.id)

    #expect(model.selectedResultIDs.isEmpty)
}

@Test @MainActor func deselectAllClearsEverything() {
    let safe = result(tier: .safe)
    let model = viewModel([safe])
    model.selectedResultIDs = [safe.id]

    model.deselectAll()

    #expect(model.selectedResultIDs.isEmpty)
}
