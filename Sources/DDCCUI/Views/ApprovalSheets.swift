import SwiftUI
import DDCCCore

/// Presented when a selection needs approval first. One view for both prompts:
/// they differ in what they name (a category, or one path) and in nothing else,
/// and two near-identical sheets would drift apart.
struct ApprovalSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    let prompt: AppViewModel.ApprovalPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            Text(tier.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            detail

            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelPendingApproval() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this sheet without changing the selection.")
                Button(confirmLabel) { viewModel.confirmPendingApproval() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help(confirmHelp)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var tier: RemovalTier {
        switch prompt {
        case .category: return .costly
        case .item: return .destructive
        case .costlyCategories: return .costly
        }
    }

    private var title: String {
        switch prompt {
        case .category(let category, _): return "Enable \(category.rawValue)?"
        case .item: return "Select this item?"
        case .costlyCategories(let categories):
            return categories.count == 1
                ? "Enable 1 costly category?"
                : "Enable \(categories.count) costly categories?"
        }
    }

    private var confirmLabel: String {
        switch prompt {
        case .category: return "Enable"
        case .item: return "Select"
        case .costlyCategories: return "Enable All"
        }
    }

    private var confirmHelp: String {
        switch prompt {
        case .category:
            return "Enable this costly category for the current scan."
        case .item:
            return "Select this destructive item only."
        case .costlyCategories:
            return "Enable these costly categories for the current scan."
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch prompt {
        case .category(let category, _):
            let rows = viewModel.results.filter {
                $0.category == category && $0.tier == .costly && $0.isDeletable
            }
            let bytes = rows.reduce(Int64(0)) { $0 + $1.sizeBytes }
            Text("\(Plural.of(rows.count, "item")) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                .font(.callout)
            Text("Enabling applies to this scan only.")
                .font(.caption)
                .foregroundStyle(.tertiary)

        case .item(let id):
            if let row = viewModel.results.first(where: { $0.id == id }) {
                Text(row.relativePath)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(row.formattedSize) · modified \(row.age)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .costlyCategories(let categories):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(categories, id: \.self) { category in
                    // filteredResults, not results: "Enable All" selects from what
                    // is in view, so these numbers must describe the same rows.
                    let rows = viewModel.filteredResults.filter {
                        $0.category == category && $0.tier == .costly && $0.isDeletable
                    }
                    let bytes = rows.reduce(Int64(0)) { $0 + $1.sizeBytes }
                    HStack {
                        Text(category.rawValue)
                        Spacer()
                        Text("\(Plural.of(rows.count, "item")) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Text("Counts cover what is currently in view. Enabling applies to this scan only.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
