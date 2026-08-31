import SwiftUI
import AppKit
import DDCCCore

struct FinderDetailView: View {
    let file: FoundFile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                file.displayName,
                systemImage: file.isBundle ? "shippingbox" : "doc"
            )
            .font(.title2)

            LabeledContent("Size", value: file.formattedSize)
            LabeledContent("Age", value: file.unmodifiedDescription)
            Text(FinderHelpTopic.ageThreshold.helpText.long)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Path", value: file.relativePath)

            if file.isBundle {
                Text(
                    "A bundle. macOS treats this as one object, so it is "
                    + "reported and removed whole."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if file.partialRead {
                Text(FinderHelpTopic.partialSize.helpText.long)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.path])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help(FinderHelpTopic.reveal.helpText.short)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
