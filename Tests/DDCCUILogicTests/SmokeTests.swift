import Testing
@testable import DDCCUI

@Test @MainActor func viewModelStartsEmpty() {
    let viewModel = AppViewModel()
    #expect(viewModel.results.isEmpty)
    #expect(viewModel.selectedResultIDs.isEmpty)
}
