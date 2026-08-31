import Testing
@testable import DDCCUI

/// Trashing the previewed file must dismiss the panel, not just reload it:
/// `url` going nil triggers `reloadData()`, and reloading a nil url has
/// nothing to draw.
@Test @MainActor func theDecisionToDismissNeedsAllThreeFactsToBeTrue() {
    #expect(QuickLookCoordinator.shouldDismiss(
        hasURL: false, isVisible: true, ownsPanel: true))

    // A url is still previewable — reload, do not dismiss.
    #expect(!QuickLookCoordinator.shouldDismiss(
        hasURL: true, isVisible: true, ownsPanel: true))
    #expect(!QuickLookCoordinator.shouldDismiss(
        hasURL: false, isVisible: false, ownsPanel: true))
    // Another view's coordinator has taken the panel; closing it would be
    // reaching into someone else's window.
    #expect(!QuickLookCoordinator.shouldDismiss(
        hasURL: false, isVisible: true, ownsPanel: false))
}
