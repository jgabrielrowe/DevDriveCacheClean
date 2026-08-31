import SwiftUI
import DDCCCore

struct MainToolbar: ToolbarContent {
    @Environment(AppViewModel.self) private var viewModel

    private var tierTwoHelp: String {
        let gated = viewModel.gatedCostlyCategories.count
        if gated == 1 { return "Review and enable 1 costly category, then select it." }
        if gated > 1 { return "Review and enable \(gated) costly categories, then select them." }
        return "Select every enabled costly item in view."
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.scanState.isActive {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: ActionGlyph.stop)
                }
                .tint(.red)
                // A promise about the scanners, not this view model:
                // `ScanCoordinator` and `FileFinder` must each keep what they
                // found on cancellation. `AppViewModel.finish` assigns
                // `results` on both outcomes whatever the report contains, so
                // it cannot confirm this on its own.
                .help("Stop the scan. Whatever it has already found stays on screen, marked as incomplete.")
            } else {
                Button {
                    viewModel.startScan()
                } label: {
                    Label("Scan", systemImage: ActionGlyph.startSweep)
                }
                .tint(.blue)
                .help("Scan the chosen folder for caches and build artifacts you can reclaim.")
            }

            Menu {
                Button("Home Directory") {
                    viewModel.scanPath = FileManager.default.homeDirectoryForCurrentUser
                }
                .help("Scan your home directory.")
                Button("Choose Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.scanPath = url
                    }
                }
                .help("Choose a different folder to scan.")
                Divider()
                Text("Current: \(PathDisplay.tildeAbbreviated(viewModel.scanPath))")
            } label: {
                Label("Scan Path", systemImage: "folder.badge.gearshape")
            }
            .help("Choose which folder DDCC scans.")
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Toggle(isOn: Binding(
                get: { viewModel.isTierFullySelected(.safe) },
                set: { viewModel.setTier(.safe, selected: $0) }
            )) {
                Label("Tier 1", systemImage: "1.circle")
            }
            // Titles as well as icons: a bare numbered circle does not say what it
            // does, disabled or not.
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.eligibleIDs(forTier: .safe).isEmpty)
            .help("Select every safe item in view.")

            Toggle(isOn: Binding(
                get: { viewModel.isTierFullySelected(.costly) },
                set: { viewModel.setCostlyTier(selected: $0) }
            )) {
                Label("Tier 2", systemImage: "2.circle")
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.visibleCostlyRowCount == 0)
            .help(tierTwoHelp)

            Button {
                viewModel.deselectAll()
            } label: {
                Label("Deselect All", systemImage: "circle")
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.selectedResults.isEmpty)
            .help("Clear the whole selection, including items opted into individually.")
        }

        ToolbarItem(placement: .status) {
            if !viewModel.selectedResultIDs.isEmpty {
                HStack(spacing: 8) {
                    Text("\(viewModel.selectedResults.count) selected (\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        viewModel.showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    // The button opens the confirmation sheet; it removes
                    // nothing itself, and the sheet's default is the Trash.
                    .help("Review the selection before anything is removed. The Trash is the default; permanent deletion is a deliberate opt-in.")
                }
            }
        }
    }
}
