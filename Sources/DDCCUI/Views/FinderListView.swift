import SwiftUI
import QuickLookUI
import DDCCCore

struct FinderListView: View {
    @Environment(FinderViewModel.self) private var viewModel
    @Binding var selectedFileID: UUID?
    @State private var quickLook = QuickLookCoordinator()

    var body: some View {
        Group {
            if viewModel.files.isEmpty {
                // A `switch` over `emptyResultsReason`, not a chain of `if
                // case` tests with a trailing `else`. That chain got this wrong
                // twice — a stopped run, then a run still in progress, each
                // described as having found nothing — because both times the
                // unhandled state fell through to the same wrong answer. This
                // is exhaustive, so a new state stops the build instead.
                switch viewModel.state.emptyResultsReason {
                case .stopped:
                    // A stopped run and a run that genuinely found nothing are
                    // different facts. The tray already said the run was
                    // stopped; the list is where the eye goes, and it was
                    // contradicting it.
                    ContentUnavailableView(
                        "Search Stopped",
                        systemImage: "stop.circle",
                        description: Text(
                            "This search was stopped before it finished, so nothing here is a complete answer. Run it again to search the whole folder.")
                    )
                case .notSearchedYet:
                    // "No Files Found" stated a result for a search that never
                    // ran. A view that has not looked yet has found nothing in
                    // a different sense than one that looked and came back
                    // empty.
                    ContentUnavailableView {
                        Label("Ready to Search", systemImage: ActionGlyph.startSweep)
                    } description: {
                        Text(FinderHelpTopic.mode.helpText.long)
                    } actions: {
                        Button("Find") { viewModel.startFind() }
                            .help(FinderHelpTopic.find.helpText.short)
                    }
                case .stillSearching:
                    // A search still running must not fall through to "No
                    // Files Found", which asserts an answer to a question still
                    // being asked — for the whole duration of the search, which
                    // on a slow root is a long time to be wrong.
                    //
                    // A bare spinner rather than a `ContentUnavailableView`,
                    // because it matches what Caches already shows for the same
                    // state, and because that view is for stating an absence —
                    // which is the one thing this state must not do.
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Searching…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                case .searchedAndFoundNothing:
                    ContentUnavailableView(
                        "No Files Found",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(FinderHelpTopic.mode.helpText.long)
                    )
                }
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                unreadableNotice
                DeletionFailureNotice(
                    failed: viewModel.lastDeletionReport?.failed ?? [],
                    operation: "moved to the Trash")
            }
        }
        .quickLookPreview(
            for: viewModel.files.first { $0.id == selectedFileID }?.path,
            coordinator: quickLook
        )
        // Without this the window title fell back to the bundle name, so the
        // Files view was headed "DDCC" while the Caches view was headed by what
        // it was showing.
        .navigationTitle(AppMode.files.title)
    }

    private var list: some View {
        List(viewModel.filteredFiles, selection: $selectedFileID) { file in
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { viewModel.selectedFileIDs.contains(file.id) },
                    set: { viewModel.setSelection(file.id, isOn: $0) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .help(FinderHelpTopic.rowCheckbox.helpText.short)

                // A bundle and a file are different facts about what the
                // size beside them means — one totals a tree, the other is
                // one file — and the glyph was the only thing saying which.
                Image(systemName: file.isBundle ? "shippingbox" : "doc")
                    .foregroundStyle(.secondary)
                    .help((file.isBundle ? ReadoutHelpTopic.foundBundle : .foundFile).helpText.short)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                    Text(file.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    // Not disabled, so the tooltip actually shows: a trailing
                    // "+" on its own says nothing about what it means.
                    if file.partialRead {
                        Text(file.formattedSize)
                            .font(.caption)
                            .help(FinderHelpTopic.partialSize.helpText.short)
                    } else {
                        Text(file.formattedSize)
                            .font(.caption)
                    }
                    Text(file.unmodifiedDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            .tag(file.id)
        }
    }

    /// The total is a floor whenever a directory could not be read. Saying so
    /// is the same rule `partialRead` follows for a single item.
    @ViewBuilder
    private var unreadableNotice: some View {
        if viewModel.unreadableDirectoryCount > 0 {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(unreadableMessage)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    /// Singular/plural handled explicitly because this message is part of the
    /// app's completeness reporting. Only the noun inflects; "could not be
    /// read" does not change between singular and plural subjects.
    private var unreadableMessage: String {
        let count = viewModel.unreadableDirectoryCount
        let noun = count == 1 ? "folder" : "folders"
        return "\(count) \(noun) could not be read. The total is a floor."
    }
}
