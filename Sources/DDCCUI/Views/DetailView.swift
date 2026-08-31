import SwiftUI
import DDCCCore

struct DetailView: View {
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: result.category.icon)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(result.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(result.category.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Info grid
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("Full Path")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(result.path.path(percentEncoded: false))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Size")
                        .foregroundStyle(.secondary)
                    Text(result.formattedSize)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }
                if result.sharesContentElsewhere {
                    GridRow {
                        Text("Shared Elsewhere")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.formattedSharedBytesWithheld)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            Text("""
                                Also reachable under another name outside this \
                                item, so removing it will not free these bytes. \
                                They are not included in the size above.
                                """)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    Text("Last Modified")
                        .foregroundStyle(.secondary)
                    Text(result.age)
                }
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: result.path.path(percentEncoded: false))
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Show this item in the Finder without touching it.")

                Button {
                    let script = "tell application \"Terminal\" to do script \"cd \\\"\(result.path.path(percentEncoded: false))\\\"\""
                    if let appleScript = NSAppleScript(source: script) {
                        var error: NSDictionary?
                        appleScript.executeAndReturnError(&error)
                    }
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .help("Open a Terminal window at this path.")
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
