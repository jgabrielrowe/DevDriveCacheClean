import Testing
import Foundation
@testable import DDCCUI
@testable import DDCCCore

/// Neither scanner reports a running item or byte count while walking — the
/// Caches coordinator reports a phase and a path, the finder reports a path.
/// The old `Int`-typed payload meant both view models had to invent a zero, and
/// a zero shown beside a spinner reads as "found nothing so far", which is a
/// claim nobody computed. `Int?` removes the ability to say it.
@Test @MainActor func neitherViewModelInventsACountWhileScanning() throws {
    let finder = FinderViewModel()

    // `searchRoot` is pointed at a fresh temp directory rather than left at its
    // `$HOME` default. `withTempDirectory` lives in the DDCCCoreTests support
    // sources and is not reachable from this target, and `cancelFind()` only
    // lands at the next directory boundary — so leaving the default would walk
    // the real home directory for real before stopping. The existing tests in
    // `FinderViewModelTests.swift` document this hazard and work around it the
    // same way; follow them rather than inventing a third pattern.
    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    finder.searchRoot = tempRoot

    finder.startFind()
    defer { finder.cancelFind() }

    guard case .scanning(_, let items, let bytes) = finder.state else {
        Issue.record("expected .scanning after startFind")
        return
    }
    #expect(items == nil)
    #expect(bytes == nil)
}
