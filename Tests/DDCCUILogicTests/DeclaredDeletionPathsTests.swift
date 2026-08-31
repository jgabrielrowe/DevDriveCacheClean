import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

/// `DeletionService` re-runs `PathGuard` immediately before removing anything.
/// A path the assembler offered from outside the scan root is refused there
/// unless it is declared again for deletion — so every such path has to appear
/// in BOTH declarations or the offer is a promise the deletion breaks.
///
/// The app's own bundle already had this treatment. Declared payloads did not,
/// and the removal failed with "path is not at least two levels below the scan
/// root" on a row the interface had just offered.

private func item(_ path: String, sources: [EvidenceSource]) -> FootprintItem {
    FootprintItem(
        path: URL(fileURLWithPath: path, isDirectory: true), sizeBytes: 1,
        evidence: .attributed(sources[0]), sources: sources,
        retainedFor: [], claimCaveat: nil, displayName: (path as NSString).lastPathComponent)
}

@Test func aDeclaredPayloadIsDeclaredForDeletionLikeAnAppBundle() {
    let items = [
        item("/Users/Shared/Epic Games", sources: [.declaredPayload]),
        item("/Applications/Epic Games Launcher.app", sources: [.appBundle]),
    ]
    let declared = UninstallViewModel.declaredPathsForDeletion(items)

    #expect(declared.contains(
        Candidate.normalizedPathKey(for: URL(fileURLWithPath: "/Users/Shared/Epic Games"))))
    #expect(declared.contains(
        Candidate.normalizedPathKey(
            for: URL(fileURLWithPath: "/Applications/Epic Games Launcher.app"))))
}

/// Declared narrowly, as the bundle rule already is: the bypass is for paths
/// this sweep attributed from outside the scan root, never for the whole item
/// set. An ordinary shelf path is inside the root and needs no declaration, and
/// declaring it would widen the bypass for nothing.
@Test func anOrdinaryShelfPathIsNotDeclaredForDeletion() {
    let items = [
        item("/Users/jrowe/Library/Caches/com.example.app", sources: [.shelf("Caches")]),
        item("/Users/jrowe/Library/Containers/com.example.app", sources: [.container]),
    ]
    #expect(UninstallViewModel.declaredPathsForDeletion(items).isEmpty)
}
