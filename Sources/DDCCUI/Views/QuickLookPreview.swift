import SwiftUI
import AppKit
import QuickLookUI

/// Drives the shared QuickLook panel for one selected file.
///
/// `QLPreviewPanel` is a single shared window with a data source rather than a
/// view you embed, so this is an NSObject bridge rather than a SwiftUI type.
/// The panel's methods accept an optional panel argument here so the data
/// source can be tested without a real panel existing.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var url: URL? {
        didSet {
            guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
            guard let panel = QLPreviewPanel.shared() else { return }
            // A file previewed and then trashed left the panel open over an
            // empty preview: `reloadData()` on a nil url has nothing to draw.
            if Self.shouldDismiss(
                hasURL: url != nil, isVisible: panel.isVisible,
                ownsPanel: panel.dataSource === self
            ) {
                panel.orderOut(nil)
                return
            }
            panel.reloadData()
        }
    }

    /// Extracted so the decision is testable without a real panel — the panel is
    /// a single shared window this process does not own outright.
    static func shouldDismiss(hasURL: Bool, isVisible: Bool, ownsPanel: Bool) -> Bool {
        !hasURL && isVisible && ownsPanel
    }

    func toggle() {
        guard url != nil else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared()?.isVisible == true {
            QLPreviewPanel.shared()?.orderOut(nil)
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    /// Releases this coordinator's hold on the shared panel, if it still has one.
    ///
    /// `QLPreviewPanel.dataSource`/`.delegate` are declared `assign` in the
    /// QuickLookUI headers — the Swift-imported equivalent of
    /// `unowned(unsafe)`, not `weak`. Nothing zeroes them out automatically,
    /// so a coordinator that deallocates (e.g. because SwiftUI tore down the
    /// view that owned it as `@State`) while still assigned leaves the panel
    /// holding a dangling pointer, not merely a leak. Identity is checked
    /// first because by the time this runs, another view's coordinator may
    /// legitimately have taken over the panel.
    func tearDown() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === self else { return }
        panel.dataSource = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, previewItemAt index: Int
    ) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

extension View {
    /// Space previews the selected file, the same gesture as Finder.
    func quickLookPreview(for url: URL?, coordinator: QuickLookCoordinator) -> some View {
        self
            .onChange(of: url) { _, newValue in coordinator.url = newValue }
            .onAppear { coordinator.url = url }
            .onDisappear { coordinator.tearDown() }
            .background {
                // The empty label is deliberate, not an oversight. This button
                // exists only to register the key equivalent; it is never
                // shown. A real label would give it real size, and `.opacity(0)`
                // does not stop hit testing — so a labelled version would sit
                // invisibly over the file list swallowing clicks. Hidden from
                // accessibility too, because an unlabelled button read aloud is
                // worse than one that is absent.
                Button("") { coordinator.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }
}
