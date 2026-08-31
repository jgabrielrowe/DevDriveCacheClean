import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

private let granted: DiskAccessProbe.Read = { _ in }
private let denied: DiskAccessProbe.Read = { _ in
    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
}
private let unknown: DiskAccessProbe.Read = { _ in
    throw NSError(domain: "Unrecognised", code: 1)
}

@MainActor
private func viewModel(_ read: @escaping DiskAccessProbe.Read) -> AppViewModel {
    let viewModel = AppViewModel(
        accessProbe: DiskAccessProbe(probePath: URL(fileURLWithPath: "/tmp/ddcc"), read: read)
    )
    viewModel.refreshDiskAccess()
    return viewModel
}

@Test @MainActor func deniedAccessShowsTheBanner() {
    #expect(viewModel(denied).showsDiskAccessBanner)
}

@Test @MainActor func grantedAccessShowsNoBanner() {
    #expect(viewModel(granted).showsDiskAccessBanner == false)
}

/// Silence beats a false alarm on a filesystem the probe does not recognise.
@Test @MainActor func unknownAccessShowsNoBanner() {
    #expect(viewModel(unknown).showsDiskAccessBanner == false)
}

@Test @MainActor func dismissingHidesTheBanner() {
    let model = viewModel(denied)
    model.diskAccessBannerDismissed = true
    #expect(model.showsDiskAccessBanner == false)
}

@Test @MainActor func relaunchIsSuggestedOnlyAfterVisitingSettings() {
    let model = viewModel(denied)
    #expect(model.suggestsRelaunch == false)
    model.markOpenedAccessSettings()
    #expect(model.suggestsRelaunch)
}

@Test @MainActor func grantingAccessAfterVisitingSettingsSuggestsNothing() {
    let model = viewModel(granted)
    model.markOpenedAccessSettings()
    #expect(model.suggestsRelaunch == false)
}
