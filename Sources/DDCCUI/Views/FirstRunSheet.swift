import AppKit
import SwiftUI

/// Shown once, before the app has been used, and never again unless the terms
/// change.
///
/// Deliberately one screen and no scrollback of licence text. A wall of terms
/// gets clicked through, teaches the user that this app's dialogs are noise,
/// and reads as a confession that the software is dangerous — which then makes
/// the confirmation sheets that *are* load-bearing easier to dismiss too.
///
/// Quit is a real button, not a courtesy. An acceptance with no way to decline
/// is a notification wearing a dialog's clothes, and it is worth less than the
/// clause it was meant to evidence.
struct FirstRunSheet: View {

    let onAgree: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Before you start", systemImage: "exclamationmark.triangle")
                .font(.title2)

            Text(
                "DDCC deletes files that you select. It moves them to the Trash by "
                + "default, so most removals can be undone — but permanent deletion "
                + "is available, and some caches cannot be regenerated."
            )

            Text(
                "The software is provided as is, without warranty of any kind. To the "
                + "fullest extent permitted by law, the licensor accepts no liability "
                + "for any loss or damage arising from its use, including lost data "
                + "and the cost of restoring it."
            )
            .foregroundStyle(.secondary)

            Text(
                "Using DDCC means accepting the Sustainable Use License, including "
                + "its No Liability section."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Button("Read the licence") {
                NSWorkspace.shared.open(Self.licenceURL)
            }
            .buttonStyle(.link)
            .help("Opens the full Sustainable Use License in your browser.")

            HStack {
                Button("Quit") { onQuit() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close DDCC without accepting. Nothing is scanned or removed.")
                Spacer()
                Button("I understand") { onAgree() }
                    .keyboardShortcut(.defaultAction)
                    .help("Accept the terms and start using DDCC.")
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 520)
        // Nothing here dismisses without a decision: Escape is bound to Quit
        // rather than to closing the sheet, so the two ways out are the two
        // answers.
        .interactiveDismissDisabled()
    }

    static let licenceURL = URL(string: "https://devdrivecacheclean.com/licence/")!
}
