import SwiftUI
import AppKit
import DDCCCore

struct FinderToolbar: ToolbarContent {
    @Environment(FinderViewModel.self) private var viewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.state.isActive {
                Button {
                    viewModel.cancelFind()
                } label: {
                    Label("Stop", systemImage: ActionGlyph.stop)
                }
                .tint(.red)
                .help(FinderHelpTopic.stop.helpText.short)
            } else {
                Button {
                    viewModel.startFind()
                } label: {
                    Label("Find", systemImage: ActionGlyph.startSweep)
                }
                .tint(.blue)
                .help(FinderHelpTopic.find.helpText.short)
            }

            Menu {
                Button("Home Directory") {
                    viewModel.searchRoot = FileManager.default.homeDirectoryForCurrentUser
                }
                .help("Search your home directory.")
                Button("Choose Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.searchRoot = url
                    }
                }
                .help("Choose a different folder to search.")
                Divider()
                Text("Current: \(PathDisplay.tildeAbbreviated(viewModel.searchRoot))")
            } label: {
                Label("Search Root", systemImage: "folder.badge.gearshape")
            }
            .help(FinderHelpTopic.root.helpText.short)
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Menu {
                Picker("Minimum size", selection: Binding(
                    get: { viewModel.criteria.minimumBytes },
                    set: { viewModel.criteria = FinderCriteria(
                        minimumBytes: $0, modifiedBeforeDays: viewModel.criteria.modifiedBeforeDays) }
                )) {
                    Text("Any size").tag(Int64(0))
                    Text("10 MB and larger").tag(Int64(10_000_000))
                    Text("100 MB and larger").tag(Int64(100_000_000))
                    Text("1 GB and larger").tag(Int64(1_000_000_000))
                }
            } label: {
                Label("Size", systemImage: "arrow.up.arrow.down.circle")
            }
            .help(FinderHelpTopic.sizeThreshold.helpText.short)

            Menu {
                Picker("Unmodified for", selection: Binding(
                    get: { viewModel.criteria.modifiedBeforeDays },
                    set: { viewModel.criteria = FinderCriteria(
                        minimumBytes: viewModel.criteria.minimumBytes, modifiedBeforeDays: $0) }
                )) {
                    Text("Any age").tag(0)
                    Text("Unmodified 30+ days").tag(30)
                    Text("Unmodified 180+ days").tag(180)
                    Text("Unmodified 1+ year").tag(365)
                }
            } label: {
                Label("Age", systemImage: "calendar.badge.clock")
            }
            .help(FinderHelpTopic.ageThreshold.helpText.short)
        }

        ToolbarItem(placement: .status) {
            if !viewModel.selectedFileIDs.isEmpty {
                HStack(spacing: 8) {
                    Text(
                        "\(viewModel.selectedFiles.count) selected "
                        + "(\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)))"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // The leading digit sat flush against the group's edge.
                    .padding(.leading, 8)

                    Button {
                        viewModel.deselectAll()
                    } label: {
                        Label("Deselect All", systemImage: "circle")
                    }
                    .help(FinderHelpTopic.deselectAll.helpText.short)

                    // Never disabled while a selection exists, and the count
                    // is in the label rather than a tooltip.
                    Button(role: .destructive) {
                        viewModel.showTrashConfirmation = true
                    } label: {
                        Label(viewModel.trashButtonTitle, systemImage: "trash")
                    }
                    .labelStyle(.titleAndIcon)
                    .tint(.red)
                    .help(FinderHelpTopic.trash.helpText.short)
                }
            }
        }
    }
}
