import SwiftUI
import DDCCCore

struct DeleteConfirmationSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var permanently = false
    @State private var typedConfirmation = ""

    private var requiresTyping: Bool { viewModel.selectionContainsDestructive }
    private var confirmationSatisfied: Bool { !requiresTyping || typedConfirmation == "DELETE" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.deleteConfirmationTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Text("This will free \(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)) of disk space.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.selectedVisibleByTier, id: \.tier) { group in
                        section(title: "\(group.tier.label) (\(group.results.count))",
                                rows: group.results, showTier: false)
                    }

                    if !viewModel.selectedHiddenResults.isEmpty {
                        section(
                            title: "⚠ Not visible in the current filter (\(viewModel.selectedHiddenResults.count))",
                            rows: viewModel.selectedHiddenResults,
                            showTier: true
                        )
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 260)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Toggle("Permanently delete (skip Trash)", isOn: $permanently)
                .toggleStyle(.checkbox)
                .help("Off, items go to the Trash and can be put back. On, they are removed immediately and cannot be recovered.")

            if permanently {
                Label("This cannot be undone.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if requiresTyping {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This selection includes destructive items. Type DELETE to confirm.")
                        .font(.caption)
                    TextField("DELETE", text: $typedConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { viewModel.showDeleteConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this sheet without removing anything.")
                Button(permanently ? "Permanently Delete" : "Move to Trash") {
                    viewModel.deleteSelected(permanently: permanently)
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(!confirmationSatisfied)
                .help(permanently
                    ? "Remove the selected cache results immediately. This cannot be undone."
                    : "Move the selected cache results to the Trash.")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func section(title: String, rows: [ScanResult], showTier: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.category.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(row.relativePath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if showTier {
                        Text(row.tier.label)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(row.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
