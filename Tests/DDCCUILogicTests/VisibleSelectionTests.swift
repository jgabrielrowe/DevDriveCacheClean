import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

private func result(category: CleanCategory, name: String) -> ScanResult {
    ScanResult(
        path: URL(fileURLWithPath: "/tmp/\(name)"),
        category: category, tier: .safe, removability: .removable,
        sizeBytes: 4096, lastModified: nil, displayName: name,
        partialRead: false, unreadablePaths: [], isDeletable: true
    )
}

private func file(name: String) -> FoundFile {
    FoundFile(
        path: URL(fileURLWithPath: "/tmp/\(name)"),
        sizeBytes: 4096, lastModified: Date(), isBundle: false, partialRead: false
    )
}

/// `files` is `private(set)`, so a fixture arrives the way a real run's rows
/// do — through `finish(_:)`. Assigning it directly would also skip whatever
/// that method does on the way in.
@MainActor
private func finderModel(_ files: [FoundFile]) -> FinderViewModel {
    let model = FinderViewModel()
    model.finish(FinderReport(
        files: files, outcome: .finished, unreadableDirectoryCount: 0,
        unmeasuredCount: 0, duration: 1.0))
    return model
}

/// The defect: the detail pane resolved its item from the UNFILTERED results
/// while the list beside it rendered the filtered ones. Selecting a row under
/// All and then choosing a category left the pane describing a Docker cache
/// next to a list of node_modules — every value in it correct, the frame as a
/// whole a lie. Worse than a stale label, because the pane carries Reveal in
/// Finder and Open in Terminal, which then act on a row the user cannot see.
@Test @MainActor func aSelectionFilteredOutOfTheCachesListLeavesThePaneEmpty() {
    let docker = result(category: .docker, name: "DockerLayers")
    let node = result(category: .nodeJS, name: "node_modules")
    let model = AppViewModel()
    model.results = [docker, node]

    // Selected while the list showed everything.
    #expect(model.visibleResult(id: docker.id)?.id == docker.id)

    // Then the user narrows to a category that excludes it.
    model.selectedCategory = .nodeJS

    #expect(model.visibleResult(id: docker.id) == nil)
    #expect(model.visibleResult(id: node.id)?.id == node.id)
}

/// Search is the other way in, and it was equally unguarded.
@Test @MainActor func aSelectionFilteredOutBySearchLeavesThePaneEmpty() {
    let docker = result(category: .docker, name: "DockerLayers")
    let node = result(category: .nodeJS, name: "node_modules")
    let model = AppViewModel()
    model.results = [docker, node]
    model.searchText = "node"

    #expect(model.visibleResult(id: docker.id) == nil)
    #expect(model.visibleResult(id: node.id)?.id == node.id)
}

/// The Files view shares the pattern: its list renders `filteredFiles` while
/// the pane resolved from `files`.
@Test @MainActor func aSelectionFilteredOutOfTheFilesListLeavesThePaneEmpty() {
    let keep = file(name: "node_modules.zip")
    let hide = file(name: "holiday.mov")
    let model = finderModel([keep, hide])
    model.searchText = "node"

    #expect(model.visibleFile(id: hide.id) == nil)
    #expect(model.visibleFile(id: keep.id)?.id == keep.id)
}

/// No selection is not the same question, and must not crash or guess.
@Test @MainActor func noSelectionResolvesToNothing() {
    let model = AppViewModel()
    model.results = [result(category: .nodeJS, name: "node_modules")]
    #expect(model.visibleResult(id: nil) == nil)

    let finder = finderModel([file(name: "a.zip")])
    #expect(finder.visibleFile(id: nil) == nil)
}
