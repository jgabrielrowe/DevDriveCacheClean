import Testing
import Foundation
@testable import DDCCCore

private func result(
    _ url: URL, sizeBytes: Int64 = 4096, isDeletable: Bool = true,
    removability: Removability = .removable
) -> ScanResult {
    ScanResult(
        path: url, category: .nodeJS, tier: .safe, removability: removability,
        sizeBytes: sizeBytes, lastModified: nil,
        displayName: "Node.js: \(url.lastPathComponent)",
        partialRead: false, unreadablePaths: [], isDeletable: isDeletable
    )
}

private func context(root: URL) -> PathGuard.Context {
    PathGuard.Context(scanRoot: root, declaredPaths: [])
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

@Test func permanentDeleteRemovesTheDirectory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/node_modules")
        try tree.file("dev/project/node_modules/index.js", byteCount: 4096)

        let report = DeletionService.delete(
            [result(target)], permanently: true, in: context(root: root))

        #expect(report.succeeded.count == 1)
        #expect(report.failed.isEmpty)
        #expect(report.bytesReclaimed == 4096)
        #expect(report.isCompleteSuccess)
        #expect(exists(target) == false)
    }
}

@Test func guardRefusalIsReportedAndThePathSurvives() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        // One level below the scan root, so PathGuard refuses it.
        let shallow = try tree.directory("Documents")

        let report = DeletionService.delete(
            [result(shallow)], permanently: true, in: context(root: root))

        #expect(report.succeeded.isEmpty)
        #expect(report.failed.count == 1)
        #expect(report.bytesReclaimed == 0)
        #expect(exists(shallow))
    }
}

/// Defence in depth: even handed a locked row directly, deletion refuses.
@Test func undeletableResultIsRefusedEvenWhenPassedDirectly() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/locked")

        let report = DeletionService.delete(
            [result(target, isDeletable: false)], permanently: true, in: context(root: root))

        #expect(report.failed.count == 1)
        #expect(exists(target))
    }
}

@Test func requiresPrivilegesResultIsRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/systemcache")

        let report = DeletionService.delete(
            [result(target, isDeletable: false, removability: .requiresPrivileges)],
            permanently: true, in: context(root: root))

        #expect(report.failed.count == 1)
        #expect(exists(target))
    }
}

@Test func oneFailureDoesNotAbortTheBatch() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let good = try tree.directory("dev/project/node_modules")
        try tree.file("dev/project/node_modules/a.js", byteCount: 2048)
        let bad = try tree.directory("Documents")

        let report = DeletionService.delete(
            [result(bad), result(good, sizeBytes: 2048)],
            permanently: true, in: context(root: root))

        #expect(report.succeeded.count == 1)
        #expect(report.failed.count == 1)
        #expect(exists(good) == false)
        #expect(exists(bad))
    }
}

@Test func vanishedPathIsReportedAsAFailure() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/node_modules")
        try FileManager.default.removeItem(at: target)

        let report = DeletionService.delete(
            [result(target)], permanently: true, in: context(root: root))

        #expect(report.failed.count == 1)
        #expect(report.bytesReclaimed == 0)
        // Pin the actual reason, not just "some failure": a vanished path
        // that would otherwise be allowed must be reported as gone, not
        // misattributed to an unrelated guard refusal (PathGuard's
        // `isRootOwned` fails closed when it cannot stat a missing file,
        // which previously surfaced as "owned by root" here).
        #expect(report.failed.first?.reason ==
            "No longer exists — it may have been removed already.")
    }
}

@Test func bytesReclaimedCountsOnlySuccesses() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let good = try tree.directory("dev/project/node_modules")
        try tree.file("dev/project/node_modules/a.js", byteCount: 1024)
        let bad = try tree.directory("Desktop")

        let report = DeletionService.delete(
            [result(good, sizeBytes: 1024), result(bad, sizeBytes: 999_999)],
            permanently: true, in: context(root: root))

        #expect(report.bytesReclaimed == 1024)
        #expect(report.isCompleteSuccess == false)
    }
}

@Test func everyFailureCarriesANonEmptyReason() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let bad = try tree.directory("Documents")
        let report = DeletionService.delete(
            [result(bad)], permanently: true, in: context(root: root))
        #expect(report.failed.allSatisfy { $0.reason.isEmpty == false })
    }
}

@Test func emptySelectionProducesAnEmptyReport() throws {
    try withTempDirectory { root in
        let report = DeletionService.delete(
            [ScanResult](), permanently: true, in: context(root: root))
        #expect(report.succeeded.isEmpty)
        #expect(report.failed.isEmpty)
        #expect(report.bytesReclaimed == 0)
        #expect(report.isCompleteSuccess)
    }
}

@Test func trashMoveIsNeverASilentNoOp() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/node_modules")
        try tree.file("dev/project/node_modules/a.js", byteCount: 1024)

        let report = DeletionService.delete(
            [result(target, sizeBytes: 1024)], permanently: false, in: context(root: root))

        // Trashing from some volumes legitimately fails, so accept either
        // outcome — but the item must be accounted for exactly once.
        #expect(report.succeeded.count + report.failed.count == 1)
        if report.succeeded.isEmpty == false {
            #expect(exists(target) == false)
        }
    }
}

/// `delete([row, row])` must not attempt the
/// same underlying path twice. A second attempt would find the path the
/// first attempt already removed, record a failure for it, and land the
/// same item in both `succeeded` and `failed` — making `isCompleteSuccess`
/// lie about a batch that fully succeeded.
@Test func duplicateEntryInTheBatchIsProcessedOnlyOnce() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/node_modules")
        try tree.file("dev/project/node_modules/a.js", byteCount: 4096)
        let row = result(target)

        let report = DeletionService.delete(
            [row, row], permanently: true, in: context(root: root))

        #expect(report.succeeded.count == 1)
        #expect(report.failed.isEmpty)
        #expect(report.isCompleteSuccess)
        #expect(report.bytesReclaimed == 4096)
        #expect(exists(target) == false)
        // The duplicate must not appear in the failure list either.
        #expect(report.failed.contains { $0.result.id == row.id } == false)
    }
}

/// The de-duplication key must go through `Candidate.normalizedPathKey(for:)`
/// rather than `result.path.path(percentEncoded: false)` directly, the way
/// every other path-identity comparison in this project does. Since `delete`
/// is public API, a caller can submit two `ScanResult`s for the very same
/// underlying path built from different URL spellings — one
/// directory-hinted (trailing slash), one not — and the un-normalized key
/// would treat them as different paths, defeating the "process each path
/// once" guarantee `duplicateEntryInTheBatchIsProcessedOnlyOnce` pins for
/// byte-identical duplicates.
@Test func differentlySpelledDuplicatePathIsProcessedOnlyOnce() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/node_modules")
        try tree.file("dev/project/node_modules/a.js", byteCount: 4096)

        let directoryHinted = URL(
            fileURLWithPath: target.path(percentEncoded: false), isDirectory: true)
        let plain = URL(
            fileURLWithPath: target.path(percentEncoded: false), isDirectory: false)
        #expect(directoryHinted.path(percentEncoded: false).hasSuffix("/"))
        #expect(plain.path(percentEncoded: false).hasSuffix("/") == false)

        let report = DeletionService.delete(
            [result(directoryHinted), result(plain)],
            permanently: true, in: context(root: root))

        #expect(report.succeeded.count == 1)
        #expect(report.failed.isEmpty)
        #expect(report.isCompleteSuccess)
        #expect(report.bytesReclaimed == 4096)
        #expect(exists(target) == false)
    }
}

/// two results whose declared `sizeBytes` sum
/// past `Int64.max` must saturate the report instead of trapping. A trap
/// here would happen AFTER both directories are already gone, destroying
/// the only record that the deletions succeeded.
@Test func bytesReclaimedSaturatesInsteadOfTrappingOnOverflow() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let first = try tree.directory("dev/project/node_modules")
        let second = try tree.directory("dev/project/other_modules")

        let report = DeletionService.delete(
            [result(first, sizeBytes: .max), result(second, sizeBytes: .max)],
            permanently: true, in: context(root: root))

        #expect(report.succeeded.count == 2)
        #expect(report.isCompleteSuccess)
        #expect(report.bytesReclaimed == Int64.max)
        #expect(exists(first) == false)
        #expect(exists(second) == false)
    }
}

/// a corrupt (negative) `sizeBytes` must not
/// reduce — or, combined with overflow, invert — the reported total.
@Test func negativeSizeBytesContributesNothingToBytesReclaimed() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("dev/project/node_modules")

        let report = DeletionService.delete(
            [result(target, sizeBytes: -1_000)], permanently: true, in: context(root: root))

        #expect(report.succeeded.count == 1)
        #expect(report.bytesReclaimed == 0)
        #expect(exists(target) == false)
    }
}

/// the `permanently` flag must route to
/// two demonstrably different operations, so swapping `removeItem` and
/// `trashItem` in the implementation would fail this test. Uses the
/// internal `FileOperations` seam rather than the real Trash: the real
/// Trash's availability and observable effects vary by volume (see
/// `trashMoveIsNeverASilentNoOp` above), which makes it unsuitable for
/// pinning a routing decision, and the seam keeps every touched path inside
/// this fixture with no dependency on `~/.Trash`.
@Test func permanentlyFlagRoutesToDistinctFileOperations() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let permanentTarget = try tree.directory("dev/project/node_modules")
        let trashTarget = try tree.directory("dev/project/other_modules")

        var removeItemCalls: [URL] = []
        var trashItemCalls: [URL] = []
        let spy = DeletionService.FileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            removeItem: { url in
                removeItemCalls.append(url)
                try FileManager.default.removeItem(at: url)
            },
            trashItem: { url in
                trashItemCalls.append(url)
                try FileManager.default.removeItem(at: url)
                return nil
            }
        )

        let permanentReport = DeletionService.delete(
            [result(permanentTarget)], permanently: true,
            in: context(root: root), fileOperations: spy)
        let trashReport = DeletionService.delete(
            [result(trashTarget)], permanently: false,
            in: context(root: root), fileOperations: spy)

        #expect(removeItemCalls == [permanentTarget])
        #expect(trashItemCalls == [trashTarget])
        #expect(permanentReport.succeeded.count == 1)
        #expect(trashReport.succeeded.count == 1)
    }
}

/// — the spy above pins `delete`'s DISPATCH (that `permanently`
/// selects the right closure), but production never runs the spy: it runs
/// `FileOperations.live`. Nothing exercised `live`'s two bindings
/// themselves, so inverting them — `live.trashItem` calling
/// `FileManager.removeItem` and vice versa — left every existing test
/// green, meaning "Move to Trash" could silently become permanent deletion
/// with no test noticing.
///
/// This calls `live` directly, with no `DeletionService.delete` in between,
/// and checks the one difference `removeItem` cannot fake: `trashItem`
/// reports a destination the item was actually moved to, which is
/// independently checked to exist and to differ from the origin.
/// `removeItem` has no destination to report — an inverted `live` would
/// either fail to compile (wrong closure shape) or, if shaped to match by
/// returning `nil`/throwing, would fail the assertions below outright.
///
/// Both fixture files are created inside `withTempDirectory` and trashed
/// from there; the only path outside the fixture this test ever touches is
/// the destination the Trash API itself reports, which is a side effect of
/// the real API, not a path this test authors. The leftover Trash item is
/// removed at the end so the test does not accumulate real Trash clutter.
@Test func liveTrashItemActuallyTrashesAndReportsWhereItWent() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let trashTarget = try tree.file("trash-me.txt", byteCount: 128)
        let removeTarget = try tree.file("remove-me.txt", byteCount: 128)

        let destination = try DeletionService.FileOperations.live.trashItem(trashTarget)
        defer {
            // Best-effort cleanup of the real Trash entry this test created.
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }

        #expect(exists(trashTarget) == false)
        let destinationURL = try #require(
            destination, "live.trashItem must report where the item went")
        #expect(exists(destinationURL))
        #expect(destinationURL.path(percentEncoded: false) !=
            trashTarget.path(percentEncoded: false))

        try DeletionService.FileOperations.live.removeItem(removeTarget)
        #expect(exists(removeTarget) == false)
    }
}

/// A minimal Deletable that is not a ScanResult, proving the service's
/// guarantees are carried by the protocol rather than by ScanResult's shape.
private struct StubDeletable: Deletable {
    let path: URL
    let sizeBytes: Int64
    let removability: Removability
    let isDeletable: Bool
    let displayName: String

    init(
        path: URL,
        sizeBytes: Int64 = 10,
        removability: Removability = .removable,
        isDeletable: Bool = true,
        displayName: String = "stub"
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.removability = removability
        self.isDeletable = isDeletable
        self.displayName = displayName
    }
}

@Test func deletionServiceTrashesANonScanResultDeletable() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let victim = try tree.file("project/victim.bin", byteCount: 10)

        var trashed: [URL] = []
        var removed: [URL] = []
        let operations = DeletionService.FileOperations(
            fileExists: { _ in true },
            removeItem: { url in removed.append(url) },
            trashItem: { url in trashed.append(url); return url }
        )

        let report = DeletionService.delete(
            [StubDeletable(path: victim)],
            permanently: false,
            in: PathGuard.Context(scanRoot: root, declaredPaths: []),
            fileOperations: operations
        )

        #expect(report.succeeded.count == 1)
        #expect(report.bytesReclaimed == 10)
        #expect(trashed.count == 1)
        #expect(removed.isEmpty, "permanently: false must never call removeItem")
    }
}

@Test func deletionServiceRefusesAnUndeletableNonScanResult() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let victim = try tree.file("locked.bin", byteCount: 10)

        let operations = DeletionService.FileOperations(
            fileExists: { _ in true },
            removeItem: { _ in Issue.record("must not remove an undeletable item") },
            trashItem: { url in Issue.record("must not trash an undeletable item"); return url }
        )

        let report = DeletionService.delete(
            [StubDeletable(path: victim, isDeletable: false)],
            permanently: false,
            in: PathGuard.Context(scanRoot: root, declaredPaths: []),
            fileOperations: operations
        )

        #expect(report.succeeded.isEmpty)
        #expect(report.failed.count == 1)
    }
}
