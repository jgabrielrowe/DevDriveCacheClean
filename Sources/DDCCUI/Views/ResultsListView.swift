import SwiftUI
import DDCCCore

struct ResultsListView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Binding var selectedResultID: UUID?

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if viewModel.filteredResults.isEmpty {
                // Switched over `emptyResultsReason` for the same reason Files
                // is: this had the identical `if / else if / else` shape and
                // avoided the bug only because `isActive` happened to be tested
                // first. Ordering is not a guarantee, and the next state added
                // would have landed in the trailing `else` here too.
                switch viewModel.scanState.emptyResultsReason {
                case .stillSearching:
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Scanning…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                case .notSearchedYet:
                    ContentUnavailableView {
                        Label("Ready to Scan", systemImage: ActionGlyph.startSweep)
                    } description: {
                        Text("Find caches and build artifacts you can reclaim.")
                    } actions: {
                        // Matches Uninstall, which offers its start control in
                        // the middle of the pane: the empty pane is where the eye
                        // already is, so pointing at a toolbar is worse than
                        // being the button.
                        Button("Scan") { viewModel.startScan() }
                            .help("Scan the chosen folder for caches and build artifacts you can reclaim.")
                    }
                case .stopped:
                    ContentUnavailableView {
                        Label("Scan Stopped", systemImage: "stop.circle")
                    } description: {
                        Text("This scan was stopped before it finished, so nothing here is a complete answer. Run it again to scan everything.")
                    }
                case .searchedAndFoundNothing:
                    ContentUnavailableView {
                        Label("No Results", systemImage: "tray")
                    } description: {
                        Text("No developer artifacts found in the selected category.")
                    }
                }
            } else {
                List(selection: $selectedResultID) {
                    HStack {
                        Text("Path")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Size")
                            .frame(width: 80, alignment: .trailing)
                        Text("Modified")
                            .frame(width: 100, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(viewModel.filteredResults) { result in
                        ResultRow(result: result)
                            .tag(result.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // A modifier on the `Group`, not a sibling inside it, and for the
            // same reason `FinderListView` does this: when every selected row
            // failed and every other row was already removed,
            // `filteredResults` is empty and the `Group` renders
            // `ContentUnavailableView` — the one moment the explanation matters
            // most. A view placed inside the `Group` would not render then.
            DeletionFailureNotice(
                failed: viewModel.lastDeletionReport?.failed ?? [],
                operation: viewModel.lastDeletionOperation)
        }
        .navigationTitle(viewModel.selectedCategory?.rawValue ?? AppMode.caches.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Sort", selection: $vm.sortOrder) {
                    ForEach(AppViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
            }
        }
    }
}

struct ResultRow: View {
    @Environment(AppViewModel.self) private var viewModel
    let result: ScanResult

    private var isSelected: Bool {
        viewModel.selectedResultIDs.contains(result.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            switch SelectionPolicy.selectability(of: result, given: viewModel.approval) {
            case .selectable:
                Button {
                    viewModel.toggleSelection(result.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("\(result.tier.label): \(result.tier.explanation)")

            case .needsCategoryAcknowledgement:
                Button {
                    viewModel.toggleSelection(result.id)
                } label: {
                    Image(systemName: "lock.circle")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("\(result.tier.label): \(result.tier.explanation)")

            case .needsItemOptIn:
                Button {
                    viewModel.toggleSelection(result.id)
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("\(result.tier.label): \(result.tier.explanation)")

            case .lockedRequiresPrivileges:
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
                    .font(.title3)
                    .help("Requires privileges DevDriveCacheClean does not have.")
            }

            // The second glyph in the row, and the only one that was
            // silent: the selection control beside it has said what its
            // tier means since it was written. Reuses the category's own
            // copy rather than describing the icon, so a row and the
            // sidebar entry it belongs to cannot say different things.
            Image(systemName: result.category.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(HelpText.for(result.category).short)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(result.category.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if result.sharesContentElsewhere {
                        // Not a warning and not a floor: the walk read every
                        // byte. It is the answer to the question the row would
                        // otherwise provoke — why this reads smaller than the
                        // same folder does in Finder.
                        Text("\(result.formattedSharedBytesWithheld) shared elsewhere")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                            .help("""
                                Content here is also reachable under another \
                                name outside this item. Removing this will not \
                                free those bytes, so they are not counted in \
                                its size.
                                """)
                    }

                    if !result.isDeletable {
                        Text("Requires privileges")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.formattedSize)
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .trailing)

            Text(result.age)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
