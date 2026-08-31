import SwiftUI
import DDCCCore

/// One app's whole assembled footprint — the removal action
/// lives here, one identity at a time, never as list checkboxes plus a
/// toolbar action. Every number and word this view renders comes from
/// `UninstallWording`/`UninstallGrouping`; nothing here computes a total
/// the tests in `UninstallPresentationTests` do not already cover.
struct UninstallDetailView: View {
    @Environment(UninstallViewModel.self) private var viewModel
    let footprint: AppFootprint

    @State private var showPermanentConfirmation = false
    @State private var showForceQuitConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let refusal = footprint.refusal {
                    refusalNotice(refusal)
                } else {
                    reclaimableSection
                    retainedSection
                    disclosedSection(
                        title: "Outside DevDriveCacheClean's Reach",
                        detail: "\(footprint.identity.displayName) owns more than what is offered above. "
                            + "These paths sit outside the folders DevDriveCacheClean is allowed to "
                            + "remove from, and were never measured.",
                        paths: footprint.disclosedOutsideAllowlist)
                    disclosedSection(
                        title: "Refused by DevDriveCacheClean's Safety Check",
                        detail: "\(footprint.identity.displayName) owns more than what is offered above. "
                            + "These paths sit inside an allowed folder but were refused anyway, by the "
                            + "same safety check every other removal goes through, and were never "
                            + "measured.",
                        paths: footprint.refusedByPathGuard)
                    actions
                }

                if let trashResult = trashResultForThisFootprint {
                    Text(trashResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DeletionFailureNotice(
                    failed: viewModel.lastDeletionReport?.failed ?? [],
                    operation: "removed")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(footprint.identity.displayName)
    }

    /// `UninstallWording.trashResultDescription`, scoped to this
    /// footprint's own row id — see `UninstallViewModel.lastTrashResultRowID`'s
    /// doc comment — so switching to a different app after a Trash move
    /// cannot show it that app's own, unrelated result. Keyed on the row id
    /// rather than the bundle id since dead artifacts joined this path and
    /// have no bundle id to key on.
    private var trashResultForThisFootprint: String? {
        guard viewModel.lastTrashResultRowID == UninstallDisplayRow.app(footprint).id,
              let bytes = viewModel.lastTrashResultBytes
        else { return nil }
        return UninstallWording.trashResultDescription(byteCount: bytes)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                footprint.identity.displayName,
                systemImage: footprint.identity.isPresent ? "app.badge" : "questionmark.app"
            )
            .font(.title2)

            // Both halves of this sentence come from `recoveryStatement`, which
            // keys the provenance clause on namespace and the "not on disk"
            // clause on `isPresent` — the same fact the glyph above renders.
            if let recovery = UninstallWording.recoveryStatement(for: footprint.identity) {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func refusalNotice(_ refusal: FootprintRefusal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(UninstallWording.refusalDescription(for: refusal), systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            // A running app is the one refusal the user can clear, which is
            // why it is listed at all — see `UninstallGrouping.sections`.
            // Nothing was measured, so there is nothing to offer and no
            // removal control here; what this pane can give is the reason and
            // the way out.
            if refusal == .appIsRunning {
                Text("Nothing was measured for \(footprint.identity.displayName), because a running "
                     + "app rewrites the state this sweep would read. Quit it and sweep again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let result = viewModel.quitResult(for: footprint) {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button {
                        viewModel.quit(footprint, force: false)
                    } label: {
                        Label("Quit", systemImage: "power")
                    }
                    .help("Ask \(footprint.identity.displayName) to quit. It may prompt you to save first.")

                    Button(role: .destructive) {
                        showForceQuitConfirmation = true
                    } label: {
                        Label("Force Quit", systemImage: "exclamationmark.octagon")
                    }
                    .tint(.red)
                    .help("Terminate \(footprint.identity.displayName) immediately. Unsaved work is lost.")
                    .confirmationDialog(
                        "Force quit \(footprint.identity.displayName)?",
                        isPresented: $showForceQuitConfirmation, titleVisibility: .visible
                    ) {
                        Button("Force Quit", role: .destructive) {
                            viewModel.quit(footprint, force: true)
                        }
                        .help("Confirm terminating the app immediately. Unsaved work is lost.")
                        Button("Cancel", role: .cancel) {}
                            .help("Close this confirmation without quitting anything.")
                    } message: {
                        Text("The app is terminated immediately, without being asked to save. "
                             + "Any unsaved work in it is lost.")
                    }
                }
            }
        }
    }

    // MARK: - Reclaimable

    private var reclaimableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reclaimable").font(.headline)
                    .help(UninstallWording.reclaimableHelp)
                Spacer()
                // Rule 2: the one number that may be presented as
                // reclaimable — never `retained`, never the two disclosure
                // lists, which carry no size at all precisely so they
                // cannot inflate this total.
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: UninstallWording.reclaimableBytes(for: footprint), countStyle: .file)
                )
                .foregroundStyle(.secondary)
            }
            if footprint.items.isEmpty {
                Text("Nothing this app owns is offered for removal.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(footprint.items) { item in
                    itemRow(item, sizeText: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                }
            }
        }
    }

    // MARK: - Retained

    @ViewBuilder
    private var retainedSection: some View {
        if !footprint.retained.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Retained").font(.headline)
                    .help(UninstallWording.retainedHelp)
                Text("Real and attributed to this app, but another product still claims it. "
                    + "Removed only once every app that claims it is gone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(footprint.retained) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        itemRow(
                            item, sizeText: ByteCountFormatter.string(
                                fromByteCount: item.sizeBytes, countStyle: .file))
                        Text(UninstallWording.retainedDescription(for: item))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: FootprintItem, sizeText: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PathDisplay.tildeAbbreviated(item.path))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(UninstallWording.evidenceStatement(for: item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // The one caveat that must reach the user rather than stay
                // in the engine: a group container nothing *scanned* still
                // claims is offered here with a size and a button, and the
                // population that answer was checked against cannot see an
                // app on an unmounted volume.
                if let caveat = UninstallWording.claimCaveatDescription(for: item) {
                    Text(caveat)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                // Warned on the row, ahead of the prompt: a password dialog
                // the user did not expect from a cleanup tool is alarming in
                // precisely the way this tool must not be.
                if item.requiresAuthentication {
                    Label(UninstallWording.authenticationNotice, systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Disclosure (no size, by design)

    @ViewBuilder
    private func disclosedSection(title: String, detail: String, paths: [DisclosedPath]) -> some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) (\(paths.count))").font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(paths.enumerated()), id: \.offset) { _, disclosed in
                    Text(PathDisplay.tildeAbbreviated(disclosed.path))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Spacer()
            Button {
                viewModel.moveToTrash(footprint)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(footprint.items.isEmpty)
            .help("Move every reclaimable item above to the Trash. Nothing is freed until the Trash is emptied.")

            Button(role: .destructive) {
                showPermanentConfirmation = true
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
            .disabled(footprint.items.isEmpty)
            .help("Delete every reclaimable item above immediately. This cannot be undone.")
            .confirmationDialog(
                "Delete \(footprint.items.count) item\(footprint.items.count == 1 ? "" : "s") permanently?",
                isPresented: $showPermanentConfirmation, titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    viewModel.removePermanently(footprint)
                }
                .help("Confirm permanent deletion of every reclaimable item above. This cannot be undone.")
                Button("Cancel", role: .cancel) {}
                    .help("Close this confirmation without deleting anything.")
            } message: {
                if let caveat = UninstallWording.permanentRemovalCaveat(for: footprint) {
                    Text("\(UninstallWording.permanentRemovalWarning)\n\n\(caveat)")
                } else {
                    Text(UninstallWording.permanentRemovalWarning)
                }
            }
        }
    }
}
