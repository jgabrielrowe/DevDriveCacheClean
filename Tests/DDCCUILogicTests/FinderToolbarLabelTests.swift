import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

/// A label-format check, not a UI guarantee. `trashButtonTitle` has two
/// consumers: the toolbar's status item, wrapped in
/// `if !viewModel.selectedFileIDs.isEmpty` so it renders nothing when nothing
/// is selected, and the confirmation sheet's button, which cannot appear with
/// an empty selection either.
///
/// The title carried its own count until both consumers were read side by
/// side: the toolbar prints "N selected (SIZE)" immediately to its left, and
/// the sheet states the count, the size and every path above it. Saying it a
/// third time crowded the control without informing anyone.

@Test @MainActor func trashButtonTitleNamesTheSelectionWithoutCountingIt() {
    let model = FinderViewModel()
    #expect(model.trashButtonTitle == "Move Selected to Trash")

    model.replaceFiles([
        FoundFile(path: URL(fileURLWithPath: "/tmp/a"), sizeBytes: 1,
                  lastModified: nil, isBundle: false),
        FoundFile(path: URL(fileURLWithPath: "/tmp/b"), sizeBytes: 1,
                  lastModified: nil, isBundle: false),
    ])
    model.toggleSelection(model.files[0].id)
    #expect(model.trashButtonTitle == "Move Selected to Trash")

    model.toggleSelection(model.files[1].id)
    #expect(model.trashButtonTitle == "Move Selected to Trash")
}

/// The word Delete must not appear on the finder's removal action: it moves
/// files to the Trash, and saying Delete would overstate what happens.
@Test @MainActor func trashButtonNeverSaysDelete() {
    let model = FinderViewModel()
    #expect(model.trashButtonTitle.localizedCaseInsensitiveContains("delete") == false)
    #expect(model.trashButtonTitle.localizedCaseInsensitiveContains("trash"))
}
