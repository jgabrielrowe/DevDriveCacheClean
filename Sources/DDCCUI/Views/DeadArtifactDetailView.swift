import SwiftUI
import DDCCCore

/// One dead artifact's detail pane — the thing it points at, where it lives,
/// and the two removal actions.
///
/// Separate from `UninstallDetailView` rather than a branch inside it. An
/// app footprint has four disjoint output categories, a retained section and
/// two disclosure lists; a dead artifact has one path and one size. Folding
/// them together would mean a pane that renders empty sections for
/// everything the artifact does not have, and every `if` in that pane would
/// be a place the two could drift.
///
/// What makes this row actionable at all: a dead artifact is already a
/// `FootprintItem`, so `DeletionService` takes it unchanged. What it does
/// not have is an identity — nothing claims it, which is the definition of
/// dead — so the removal is scoped by row id rather than by bundle id.
struct DeadArtifactDetailView: View {
    @Environment(UninstallViewModel.self) private var viewModel
    let item: FootprintItem

    @State private var showPermanentConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                evidence

                if let trashResult {
                    Text(trashResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                actions

                DeletionFailureNotice(
                    failed: viewModel.lastDeletionReport?.failed ?? [],
                    operation: "removed")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.displayName, systemImage: "xmark.bin")
                .font(.title2)
            Text(UninstallWording.evidenceStatement(for: .deadArtifact(item)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reclaimable").font(.headline)
                    .help(UninstallWording.reclaimableHelp)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            // No retained section and no disclosure lists, because a dead
            // artifact can have neither: nothing claims it, and it reached
            // this pane only by surviving `PathGuard` inside an allowlisted
            // root.
            Text(PathDisplay.tildeAbbreviated(item.path))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
    }

    /// Scoped to this artifact's own row, the same rule the app pane
    /// follows: after a Trash move, selecting a different row must not show
    /// it someone else's result.
    private var trashResult: String? {
        guard viewModel.lastTrashResultRowID == UninstallDisplayRow.deadArtifact(item).id,
              let bytes = viewModel.lastTrashResultBytes
        else { return nil }
        return UninstallWording.trashResultDescription(byteCount: bytes)
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button {
                viewModel.moveToTrash(deadArtifact: item)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move this artifact to the Trash. Nothing is freed until the Trash is emptied.")

            Button(role: .destructive) {
                showPermanentConfirmation = true
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
            .help("Delete this artifact immediately. This cannot be undone.")
            .confirmationDialog(
                "Delete \(item.displayName) permanently?",
                isPresented: $showPermanentConfirmation, titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    viewModel.removePermanently(deadArtifact: item)
                }
                .help("Confirm permanent deletion of this artifact. This cannot be undone.")
                Button("Cancel", role: .cancel) {}
                    .help("Close this confirmation without deleting anything.")
            } message: {
                Text(UninstallWording.permanentRemovalWarning)
            }
        }
    }
}
