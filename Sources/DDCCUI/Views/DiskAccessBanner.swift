import SwiftUI
import DDCCCore

/// Advisory only. Scanning stays enabled without Full Disk Access; results are
/// marked as partial reads instead. Blocking the user would be worse than a
/// visible undercount they have been told about.
struct DiskAccessBanner: View {
    @Environment(AppViewModel.self) private var viewModel

    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Some folders can't be read")
                    .fontWeight(.medium)
                Text("Without Full Disk Access, sizes marked with + are undercounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.suggestsRelaunch {
                    Text("If you just granted access, quit and reopen DevDriveCacheClean for it to take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button("Open Settings") {
                viewModel.markOpenedAccessSettings()
                NSWorkspace.shared.open(Self.settingsURL)
            }
            .help("Open the macOS Full Disk Access settings.")

            Button {
                viewModel.diskAccessBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss until next launch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}
