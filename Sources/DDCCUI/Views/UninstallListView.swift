import SwiftUI
import DDCCCore

/// One row per app identity, plus a section for dead artifacts. Grouping
/// and ordering come entirely from `UninstallGrouping.sections(for:)` — see
/// `UninstallPresentation.swift` — this view only renders what that
/// function already decided.
struct UninstallListView: View {
    @Environment(UninstallViewModel.self) private var viewModel
    @Binding var selectedRowID: String?

    var body: some View {
        @Bindable var vm = viewModel

        return Group {
            if viewModel.isSweeping && viewModel.report == nil {
                ContentUnavailableView {
                    Label("Sweeping…", systemImage: "trash.square")
                } description: {
                    Text(viewModel.currentPhaseDescription ?? "Looking for what every installed app left behind.")
                }
            } else if viewModel.sections.isEmpty {
                ContentUnavailableView {
                    Label("No Sweep Yet", systemImage: "trash.square")
                } description: {
                    Text("Sweep to see what installed apps — and apps already gone — left behind.")
                } actions: {
                    Button("Sweep") { viewModel.startSweep() }
                        .help("Scan every installed app, and every app already gone, for what it left behind.")
                }
            } else {
                list
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                unavailableSourcesNotice
                reportDisclosuresNotice
            }
        }
        .navigationTitle(AppMode.uninstall.title)
        .toolbar {
            // The Caches view's shape, in the same slot: a segmented picker
            // in the principal position. Uninstall shipped without one on
            // the reasoning that its sections already give the list a
            // structure to scan by eye — true of three sections, less true
            // the longer the machine's list of apps.
            ToolbarItem(placement: .principal) {
                Picker("Sort", selection: $vm.sortOrder) {
                    ForEach(UninstallSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                .help("Order apps by total footprint, by what they offer, or by name.")
            }

            ToolbarItem {
                // The Caches toolbar's convention: Stop replaces the start
                // control while the run is active, rather than sitting
                // beside a disabled one. A sweep the user cannot stop is a
                // sweep they abandon, and an abandoned sweep shows them no
                // number at all.
                if viewModel.isSweeping {
                    Button {
                        viewModel.cancelSweep()
                    } label: {
                        Label("Stop", systemImage: ActionGlyph.stop)
                    }
                    .tint(.red)
                    .help("Stop the sweep. Whatever it has already found stays on screen, marked as incomplete.")
                } else {
                    Button {
                        viewModel.startSweep()
                    } label: {
                        Label("Sweep", systemImage: ActionGlyph.startSweep)
                    }
                    .help("Scan every installed app, and every app already gone, for what it left behind.")
                }
            }
        }
    }

    private var list: some View {
        List(selection: $selectedRowID) {
            ForEach(viewModel.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        UninstallRowView(row: row)
                            .tag(row.id)
                    }
                }
            }
        }
        .onChange(of: selectedRowID) { _, newValue in
            viewModel.selectedRowID = newValue
        }
    }

    @ViewBuilder
    private var unavailableSourcesNotice: some View {
        let sources = viewModel.displayUnavailableSources
        if !sources.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Not available: \(sources.joined(separator: "; "))")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    /// `unattributedBytes` and
    /// `deadArtifactGuardRefusals` are report-level facts — real disk
    /// space this sweep found and could attribute to no known app, and
    /// `PathGuard` refusals met while looking for dead artifacts that
    /// belong to no app row. Neither can ever reach a detail pane, since
    /// neither is attached to any one identity, so this list is the only
    /// surface either one can appear on. Rule 3 is satisfied per-app by
    /// each footprint's own disclosure lists; this is where it is
    /// satisfied per-report.
    @ViewBuilder
    private var reportDisclosuresNotice: some View {
        if let report = viewModel.report {
            let unattributed = UninstallWording.unattributedBytesDescription(report.unattributedBytes)
            let deadRefusals = UninstallWording.deadArtifactGuardRefusalsDescription(report.deadArtifactGuardRefusals)
            if unattributed != nil || deadRefusals != nil {
                VStack(spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        if let unattributed {
                            Text(unattributed).font(.caption)
                        }
                        if let deadRefusals {
                            Text(deadRefusals).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
    }
}

/// One row's summary: name, provenance for a recovered identity or a dead
/// artifact's target, its evidence sources, and — for an app row — its
/// reclaimable bytes labelled as such, with retained bytes shown as a
/// second, separately labelled figure only when there are any. Never an
/// unlabelled combined total, and never
/// the button that acts on it — that lives in the detail pane, one
/// identity at a time.
private struct UninstallRowView: View {
    let row: UninstallDisplayRow

    var body: some View {
        switch row {
        case .app(let footprint):
            HStack(spacing: 12) {
                Image(systemName: footprint.identity.isPresent ? "app.badge" : "questionmark.app")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(footprint.identity.displayName)
                    if let recovery = UninstallWording.recoveryEvidenceDescription(for: footprint.identity) {
                        Text(recovery)
                            .rowSubtitle()
                    }
                    if let refusal = footprint.refusal {
                        // A refused footprint was never
                        // measured, so it gets its reason and a lock glyph
                        // where the figures would be — never a zero, which
                        // is indistinguishable from an app genuinely
                        // measured at zero and means the opposite thing.
                        // Only `.appIsRunning` reaches here;
                        // `UninstallGrouping.sections(for:)` drops the
                        // permanent `.appleOwned` refusal from the list
                        // entirely.
                        Label(
                            UninstallWording.refusalDescription(for: refusal),
                            systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        // Every row states its evidence sources — a size and
                        // a name with nothing saying why the engine believes
                        // the app owns any of it is an unexplained
                        // attribution.
                        Text(UninstallWording.evidenceStatement(for: row))
                            .rowSubtitle()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                // Labelled, and never the unlabelled combined total: an
                // unlabelled number beside an app name in a cleaning tool
                // reads as "what I get back," which overstates it whenever
                // anything is retained.
                // Suppressed entirely for a refused footprint: see above.
                if footprint.refusal == nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Reclaimable \(byteText(UninstallWording.reclaimableBytes(for: footprint)))")
                            .font(.caption)
                            .help(UninstallWording.reclaimableHelp)
                        // The call sits inside the same interpolation as
                        // its own label rather than behind a local `let`.
                        // A label and a figure bound on separate lines can
                        // be swapped with each other and read as correct
                        // code; keeping each pairing to one line is what
                        // lets `theListRowPairsEachLabelWithItsOwnFigure`
                        // see the swap at all.
                        if UninstallWording.retainedBytes(for: footprint) > 0 {
                            Text("Retained \(byteText(UninstallWording.retainedBytes(for: footprint)))")
                                .font(.caption2)
                                .help(UninstallWording.retainedHelp)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        case .deadArtifact(let item):
            HStack(spacing: 12) {
                Image(systemName: "xmark.bin")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                    Text(UninstallWording.evidenceStatement(for: row))
                        .rowSubtitle()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
