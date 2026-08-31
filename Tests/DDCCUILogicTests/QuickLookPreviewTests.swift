import Testing
import Foundation
import QuickLookUI
@testable import DDCCUI

@Test @MainActor func coordinatorReportsOneItemWhenAURLIsSet() {
    let coordinator = QuickLookCoordinator()
    #expect(coordinator.numberOfPreviewItems(in: nil) == 0)

    coordinator.url = URL(fileURLWithPath: "/tmp/preview-me.txt")
    #expect(coordinator.numberOfPreviewItems(in: nil) == 1)
}

@Test @MainActor func coordinatorHandsBackTheURLItWasGiven() throws {
    let coordinator = QuickLookCoordinator()
    let url = URL(fileURLWithPath: "/tmp/preview-me.txt")
    coordinator.url = url

    let item = try #require(coordinator.previewPanel(nil, previewItemAt: 0) as? NSURL)
    #expect(item as URL == url)
}

@Test @MainActor func coordinatorWithNoURLHandsBackNothing() {
    let coordinator = QuickLookCoordinator()
    #expect(coordinator.previewPanel(nil, previewItemAt: 0) == nil)
}

// toggle()'s open path and the visible/`isVisible` branch both require a
// real, orderable QLPreviewPanel window, which does not exist in a `swift
// test` process (no running app). Only the nil-url no-op path is safe to
// assert here without risking a test that only passes in a GUI session.
@Test @MainActor func toggleWithNoURLDoesNothing() {
    let coordinator = QuickLookCoordinator()
    #expect(QLPreviewPanel.sharedPreviewPanelExists() == false)

    coordinator.toggle()

    #expect(QLPreviewPanel.sharedPreviewPanelExists() == false)
}

@Test @MainActor func tearDownWithNoPanelDoesNothing() {
    let coordinator = QuickLookCoordinator()
    #expect(QLPreviewPanel.sharedPreviewPanelExists() == false)

    coordinator.tearDown()

    #expect(QLPreviewPanel.sharedPreviewPanelExists() == false)
}
