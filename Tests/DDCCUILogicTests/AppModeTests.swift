import Testing
@testable import DDCCUI

@Test func appStartsInCachesMode() async {
    await MainActor.run {
        #expect(AppViewModel().mode == .caches)
    }
}

@Test func everyModeHasATitleAndAnIcon() {
    for mode in AppMode.allCases {
        #expect(mode.title.isEmpty == false, "\(mode)")
        #expect(mode.icon.isEmpty == false, "\(mode)")
    }
}

/// Switching modes must not disturb what the other mode found. The two
/// lifecycles are independent, and a mode switch is a view change, not a
/// reset.
@Test func switchingModesLeavesCachesStateAlone() async {
    await MainActor.run {
        let model = AppViewModel()
        model.selectedCategory = .nodeJS
        model.mode = .files
        model.mode = .caches
        #expect(model.selectedCategory == .nodeJS)
    }
}
