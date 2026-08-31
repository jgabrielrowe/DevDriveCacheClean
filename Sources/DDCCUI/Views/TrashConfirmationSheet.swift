import SwiftUI
import DDCCCore

/// Lists every selected path before anything moves. These rows are unaudited,
/// so full disclosure is the only safeguard between the user and a mistake —
/// there is no tier here to reason about on their behalf.
struct TrashConfirmationSheet: View {
    @Environment(FinderViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move to Trash", systemImage: "trash")
                .font(.title2)

            Text(
                "\(Plural.of(viewModel.selectedFiles.count, "item")), "
                + "\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)). "
                + "They go to the Trash and can be put back."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            List(viewModel.selectedFiles) { file in
                HStack {
                    Text(file.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(file.formattedSize)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .frame(minHeight: 200)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this sheet without moving anything.")
                Button(viewModel.trashButtonTitle) {
                    viewModel.moveSelectedToTrash()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
                .help("Move the selected files and bundles to the Trash.")
            }
        }
        .padding()
        .frame(width: 560, height: 420)
    }
}
