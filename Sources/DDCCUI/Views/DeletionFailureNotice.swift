import SwiftUI
import DDCCCore

/// The visible half of a partly-failed deletion, for both views.
///
/// A deletion can fail per row — most often because the tree changed after the
/// run finished. Without this, a failed row simply stayed in the list, still
/// selected, with nothing on screen explaining why it did not go, and clicking
/// the button again failed identically. Rendered as a bar rather than a tooltip:
/// a row that looks inert with no visible message is exactly the failure mode
/// the Tier 2 bulk-acknowledgement work already fixed once, for the same reason.
///
/// Generic over `Deletable` and shared by both list views, because it existed
/// on the Files side only and the Caches side went without it for a full
/// release. One implementation cannot be backported to half the app.
struct DeletionFailureNotice<T: Deletable>: View {
    let failed: [DeletionFailure<T>]
    /// What was attempted, as a past-participle phrase: "moved to the Trash",
    /// "deleted permanently". A parameter rather than a constant because the
    /// Caches view genuinely offers both and must not claim the wrong one.
    let operation: String

    var body: some View {
        if !failed.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private var message: String {
        let reason = failed.first?.reason ?? ""
        guard failed.count > 1 else {
            return "1 item could not be \(operation): \(reason)"
        }
        return "\(Plural.of(failed.count, "item")) could not be \(operation). First reason: \(reason)"
    }
}
