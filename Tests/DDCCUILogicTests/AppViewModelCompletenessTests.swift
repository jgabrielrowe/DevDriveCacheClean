import Foundation
import Testing
@testable import DDCCCore
@testable import DDCCUI

/// `AppViewModel.finish` is the Caches path's terminal-state boundary — the
/// scan the app runs on first launch. It wires `report.completeness` through,
/// and needs a test of its own rather than resting on symmetry with
/// `FinderViewModel.finish`: hardcoded `ScanCompleteness` zeros survive review
/// precisely when nothing exercises the path that would expose them.

private func scanResult(sizeBytes: Int64, displayName: String) -> ScanResult {
    ScanResult(
        path: URL(fileURLWithPath: "/tmp/ddcc-completeness-\(UUID().uuidString)"),
        category: .xcode,
        tier: .safe,
        removability: .removable,
        sizeBytes: sizeBytes,
        lastModified: nil,
        displayName: displayName,
        partialRead: false,
        unreadablePaths: [],
        isDeletable: true
    )
}

/// The tray reads `scanState`, so a report's completeness that never reaches
/// the state is a fact gathered and then dropped. Asserted on the value, not
/// merely `!isExact`, so a mutation that swaps in some other non-exact
/// completeness cannot pass unnoticed.
@Test @MainActor func finishCarriesTheFinishedReportsCompletenessIntoTheState() {
    let model = AppViewModel()
    let completeness = ScanCompleteness(
        unreadableDirectories: 7, flooredItems: 0, unmeasuredItems: 0)
    let report = ScanReport(
        results: [], outcome: .finished, duration: 1.0, completeness: completeness)

    model.finish(report)

    guard case .completed(_, _, _, let stateCompleteness) = model.scanState else {
        Issue.record("expected .completed")
        return
    }
    #expect(stateCompleteness == completeness)
    #expect(stateCompleteness.unreadableDirectories == 7)
    #expect(!stateCompleteness.isExact)
}

/// A stopped scan reports what it found rather than nothing, and carries the
/// report's completeness rather than silently upgrading to `.exact`. The two
/// results have distinct, non-round sizes so a broken sum (e.g. only the
/// first item's bytes, or `count * sizeBytes`) cannot coincidentally match
/// the expected total.
@Test @MainActor func finishCarriesTheCancelledReportsResultsAndCompletenessIntoTheState() {
    let model = AppViewModel()
    let results = [
        scanResult(sizeBytes: 401_777, displayName: "a"),
        scanResult(sizeBytes: 202_303, displayName: "b"),
    ]
    let completeness = ScanCompleteness(
        unreadableDirectories: 0, flooredItems: 2, unmeasuredItems: 5)
    let report = ScanReport(
        results: results, outcome: .cancelled, duration: 1.0, completeness: completeness)

    model.finish(report)

    guard case .cancelled(let items, let bytes, let stateCompleteness) = model.scanState else {
        Issue.record("expected .cancelled")
        return
    }
    #expect(items == 2)
    #expect(bytes == 604_080)
    #expect(stateCompleteness == completeness)
}
