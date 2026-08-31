import Testing
import Foundation
@testable import DDCCCore

private func context(for root: URL) -> PathGuard.Context {
    PathGuard.Context(scanRoot: root, declaredPaths: ScanProfile.declaredAbsolutePaths)
}

private func allMatching(minimumBytes: Int64 = 0) -> FinderCriteria {
    FinderCriteria(minimumBytes: minimumBytes, modifiedBeforeDays: 0)
}

@Test func finderReportsFilesOverTheSizeThresholdOnly() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("big.bin", byteCount: 200_000)
        try tree.file("small.bin", byteCount: 10)

        let report = await FileFinder().run(
            root: root,
            criteria: FinderCriteria(minimumBytes: 100_000, modifiedBeforeDays: 0),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.outcome == .finished)
        #expect(report.files.map(\.displayName) == ["big.bin"])
    }
}

@Test func finderExcludesFilesModifiedAfterTheCutoff() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let old = try tree.file("old.bin", byteCount: 1_000)
        try tree.file("new.bin", byteCount: 1_000)

        let longAgo = Date(timeIntervalSinceNow: -60 * 60 * 24 * 365)
        try FileManager.default.setAttributes(
            [.modificationDate: longAgo], ofItemAtPath: old.path(percentEncoded: false))

        let report = await FileFinder().run(
            root: root,
            criteria: FinderCriteria(minimumBytes: 0, modifiedBeforeDays: 30),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.map(\.displayName) == ["old.bin"])
    }
}

/// A bundle is one object to macOS and to the user. Trashing part of a
/// .photoslibrary is not a coherent operation, so the traversal stops at the
/// boundary and reports the bundle whole.
@Test func finderReportsABundleAsOneRowNotItsContents() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let bundle = try tree.directory("Library.photoslibrary")
        try tree.file("Library.photoslibrary/database/photos.db", byteCount: 50_000)
        try tree.file("Library.photoslibrary/originals/IMG_0001.jpg", byteCount: 60_000)

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.count == 1)
        let found = try #require(report.files.first)
        #expect(found.displayName == bundle.lastPathComponent)
        #expect(found.isBundle)
        #expect(found.sizeBytes >= 110_000, "a bundle's size is the sum of its contents")
    }
}

/// The skip list must be checked against the search root itself, not only
/// against its children. A root picker pointed straight at a directory named
/// `node_modules` would otherwise walk it in full and re-report its contents
/// as anonymous rows — exactly the bytes the Caches view already explains
/// with a tier, but without the tier.
@Test func finderRootThatIsASkippedDirectoryNameYieldsNoFiles() async throws {
    try await withTempDirectory { parent in
        let root = parent.appending(path: "node_modules", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tree = FixtureTree(root: root)
        try tree.file("huge.bin", byteCount: 500_000)

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.isEmpty)
        #expect(report.outcome == .finished)
        #expect(report.unreadableDirectoryCount == 0)
    }
}

/// Companion to the directory-name case above: a root matching one of the
/// declared ABSOLUTE paths (the `~/.cargo/registry`-style entries `skipsPath`
/// exists for) must also be refused before traversal, not just a directory
/// bearing a skipped NAME.
@Test func finderRootUnderADeclaredAbsolutePathYieldsNoFiles() async throws {
    try await withTempDirectory { parent in
        let declaredRoot = parent.appending(path: "registry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: declaredRoot, withIntermediateDirectories: true)
        let tree = FixtureTree(root: declaredRoot)
        try tree.file("huge.bin", byteCount: 500_000)

        let report = await FileFinder().run(
            root: declaredRoot,
            criteria: allMatching(),
            skipList: FinderSkipList(
                declaredPaths: [declaredRoot.path(percentEncoded: false)]),
            guardContext: context(for: declaredRoot),
            onProgress: { _ in }
        )

        #expect(report.files.isEmpty)
        #expect(report.outcome == .finished)
        #expect(report.unreadableDirectoryCount == 0)
    }
}

/// The child call site is exercised by nothing else:
/// `finderRootUnderADeclaredAbsolutePathYieldsNoFiles` above only covers the
/// ROOT call site. Declaring the child directory itself as a declared absolute
/// path makes `FinderSkipList.skipsPath` return via its exact-match test
/// (`$0 == key + "/"`) before the prefix test below it (`key.hasPrefix($0)`)
/// is ever evaluated, so
/// despite the name this does not reach the prefix branch —
/// `finderRootInsideADeclaredAbsolutePathYieldsNoFiles` below is the one that
/// does.
@Test func aWalkSkipsAChildThatExactlyMatchesADeclaredAbsolutePath() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let declared = root.appending(path: "declared-cache", directoryHint: .isDirectory)
        try tree.directory("declared-cache")
        try tree.file("declared-cache/inside.bin", byteCount: 200_000)
        try tree.file("outside.bin", byteCount: 200_000)

        let report = await FileFinder().run(
            root: root,
            criteria: FinderCriteria(minimumBytes: 1, modifiedBeforeDays: 0),
            skipList: FinderSkipList(declaredPaths: [
                Candidate.normalizedPathKey(for: declared)
            ]),
            guardContext: PathGuard.Context(scanRoot: root, declaredPaths: []),
            onProgress: { _ in })

        #expect(report.files.map(\.displayName) == ["outside.bin"])
    }
}

/// The prefix line in `skipsPath` — as opposed to the exact-match line above
/// it — is reachable through a walk in exactly one situation: the root picker
/// aimed INSIDE a declared path rather than at it. Everything else is closed
/// off, because the walk never descends into a declared directory, so no
/// child key can be a strict descendant of one.
@Test func finderRootInsideADeclaredAbsolutePathYieldsNoFiles() async throws {
    try await withTempDirectory { parent in
        let declared = parent.appending(path: "registry", directoryHint: .isDirectory)
        let inside = declared.appending(path: "cache/deep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let tree = FixtureTree(root: inside)
        try tree.file("huge.bin", byteCount: 500_000)

        let report = await FileFinder().run(
            root: inside,
            criteria: allMatching(),
            skipList: FinderSkipList(
                declaredPaths: [declared.path(percentEncoded: false)]),
            guardContext: context(for: inside),
            onProgress: { _ in }
        )

        #expect(report.files.isEmpty)
        #expect(report.outcome == .finished)
    }
}

@Test func finderDoesNotDescendIntoSkippedDirectories() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("node_modules/huge.bin", byteCount: 500_000)
        try tree.file("keep.bin", byteCount: 500_000)

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.map(\.displayName) == ["keep.bin"])
    }
}

/// A bundle's total is measured by walking its contents (`SizeCalculator`),
/// and that walk can itself hit an unreadable descendant. The row must carry
/// the same "this is a floor" signal `ScanResult.partialRead` carries,
/// rather than presenting an understated number as complete.
@Test func finderFlagsABundleWithUnreadableContentsAsPartialRead() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        _ = try tree.directory("Library.photoslibrary")
        try tree.file("Library.photoslibrary/database/photos.db", byteCount: 50_000)
        let locked = try tree.directory("Library.photoslibrary/locked")
        try tree.file("Library.photoslibrary/locked/secret.bin", byteCount: 20_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
        }

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.count == 1)
        let found = try #require(report.files.first)
        #expect(found.partialRead)
        #expect(found.formattedSize.hasSuffix("+"))
    }
}

@Test func finderCountsUnreadableDirectoriesRatherThanHidingThem() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let blocked = try tree.directory("blocked")
        try tree.file("blocked/hidden.bin", byteCount: 500_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: blocked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: blocked.path(percentEncoded: false))
        }

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.unreadableDirectoryCount >= 1)
    }
}

/// A directory read can hand back entries *and* report a failure — the
/// SMB/NFS/FUSE case. `getattrlistbulk` cannot be made to do that on demand
/// against a temp-dir fixture, so this drives it through the `listDirectory`
/// seam. Treating `readFailed` as a reason to skip the directory discards the
/// entries just handed over.
@Test func finderStillReportsEntriesFromATruncatedListingAfterAFailedRead() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        // Created for real, not just described by the injected listing:
        // `PathGuard` (consulted after the seam hands back the entry) stats
        // the actual path, and a non-existent path fails closed as refused.
        // The seam controls what the *reader* claims about the directory,
        // not what exists on disk.
        let child = try tree.file("kept.bin", byteCount: 1_000)
        let truncatedRootListing = BulkDirectoryListing(
            entries: [
                BulkEntry(name: "kept.bin", isDirectory: false, sizeBytes: 1_000, modified: nil)
            ],
            readFailed: true,
            failedEntryCount: 0
        )

        let finder = FileFinder(listDirectory: { url in
            url == root
                ? truncatedRootListing
                : BulkDirectoryListing(entries: [], readFailed: false, failedEntryCount: 0)
        })

        let report = await finder.run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.map(\.displayName) == [child.lastPathComponent])
        #expect(report.unreadableDirectoryCount == 1)
    }
}

/// Companion to the unreadable-directory test above: a directory the reader
/// legitimately opened and found nothing in must NOT be counted. Without
/// this, loosening the `readFailed` check to
/// `listing.readFailed || listing.entries.isEmpty` still passes the whole
/// suite — this is the test that makes "empty is not a failure" a pinned
/// behavior rather than a comment.
@Test func finderDoesNotCountAGenuinelyEmptyDirectoryAsUnreadable() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("empty")

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.unreadableDirectoryCount == 0)
    }
}

/// Equal-sized rows reordering between runs makes the list look like it changed
/// when nothing did. Size descending stays the primary order; path breaks ties.
@Test func equalSizedRowsKeepAStableOrder() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for name in ["c.bin", "a.bin", "b.bin", "e.bin", "d.bin"] {
            try tree.file(name, byteCount: 200_000)
        }

        let paths = { () async -> [String] in
            let report = await FileFinder().run(
                root: root,
                criteria: allMatching(minimumBytes: 1),
                skipList: FinderSkipList(declaredPaths: []),
                guardContext: context(for: root),
                onProgress: { _ in })
            return report.files.map(\.displayName)
        }

        let first = await paths()
        #expect(first == ["a.bin", "b.bin", "c.bin", "d.bin", "e.bin"])
        // Twice, because an order that happens to match on one run proves
        // nothing about the next.
        #expect(await paths() == first)
    }
}

@Test func finderSortsResultsLargestFirst() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("small.bin", byteCount: 1_000)
        try tree.file("large.bin", byteCount: 10_000)
        try tree.file("medium.bin", byteCount: 5_000)

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.map(\.displayName) == ["large.bin", "medium.bin", "small.bin"])
    }
}

/// `FoundFile.isDeletable` is unconditionally `true`, which is only sound
/// because a `PathGuard`-refused path is dropped during traversal rather
/// than emitted with a flag. A symlink is refused by `PathGuard` outright
/// (never followed, never deleted as if it were its target), so it is the
/// simplest fixture that exercises this without touching the depth rule.
@Test func finderDropsAPathGuardRefusedSymlinkButKeepsTheRealFile() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let real = try tree.file("real.bin", byteCount: 1_000)
        try tree.symlink("link-to-real.bin", to: real)

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.files.map(\.displayName) == ["real.bin"])
    }
}

/// Cancellation is deterministic, not a timing bet: `onProgress` fires
/// synchronously on this task, so cancelling the current task from inside it
/// guarantees `Task.isCancelled` before the next iteration.
///
/// Cancelling on the *second* call, not the first: progress is throttled to the
/// first directory plus every 64th, and the first call fires before any entries
/// have been collected, so the test could not distinguish "a partial set was
/// kept" from "there was never a partial set".
///
/// Two things are pinned. `progressCount.calls == 2` pins the early exit itself
/// — without the in-loop check the report shape is unchanged, because the
/// terminal check re-derives `.cancelled` anyway. And the rows found before
/// cancellation survive into the report, marked `.cancelled` so a partial set
/// never reads as a whole one.
@Test func taskCancellationMidWalkReportsCancelledKeepingPartialResults() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<200 {
            try tree.file("dir-\(index)/file.bin", byteCount: 1_000)
        }

        final class ProgressCount: @unchecked Sendable { var calls = 0 }
        let progressCount = ProgressCount()

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in
                progressCount.calls += 1
                if progressCount.calls == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        #expect(report.outcome == .cancelled)
        #expect(!report.files.isEmpty, "a partial set is only honest when the outcome says so")
        #expect(
            progressCount.calls == 2,
            "the walk must stop shortly after cancellation lands, not run to completion")
    }
}

/// `run` has two cancelled-branch returns: the mid-walk early return above,
/// and the final return after the `while` loop exits on its own. The
/// mid-walk test cancels while the queue still has directories left, so it
/// only ever exercises the early return — the final return's own `files:`
/// line (`found.sorted { ... }`) is otherwise untested, confirmed by mutating
/// it to `cancelledNow ? [] : found.sorted { ... }` and observing the full
/// suite pass anyway.
///
/// This closes that gap. The fixture is a single flat directory with no
/// subdirectories, so after processing it the queue is empty and the `while`
/// loop ends on its own rather than being caught by the mid-walk check.
/// Cancelling from the first (and only) `onProgress` call lands after that
/// call's mid-walk check already passed, so the directory's files are still
/// added to `found` before the loop exits into the final return.
@Test func taskCancellationOnTheLastDirectoryKeepsThatDirectorysFiles() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<50 {
            try tree.file("file-\(index).bin", byteCount: 1_000)
        }

        let report = await FileFinder().run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )

        #expect(report.outcome == .cancelled)
        #expect(
            report.files.count == 50,
            "the loop exits into the final return here, not the mid-walk early return")
    }
}

/// Distinct from task cancellation above: this pins the actor's own sticky
/// `isCancelled` flag, set through the public `cancel()` API before `run`
/// is ever invoked, independent of `Task` cancellation entirely.
@Test func cancelCalledBeforeRunStillReportsCancelled() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("file.bin", byteCount: 1_000)

        let finder = FileFinder()
        await finder.cancel()
        let report = await finder.run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.outcome == .cancelled, "a partial set is only honest when the outcome says so")
        // Legitimately empty here, unlike the mid-walk test above: `cancel()`
        // was called before `run` ever started, so there was no partial set
        // to keep in the first place. Asserting non-emptiness here would be
        // wrong, not stronger.
        #expect(report.files.isEmpty)
    }
}

/// Both thresholds apply together, and either can be disengaged.
@Test func criteriaCombineWithAnd() {
    let criteria = FinderCriteria(minimumBytes: 1_000, modifiedBeforeDays: 5)
    let old = Date(timeIntervalSinceNow: -60 * 60 * 24 * 10)
    let recent = Date()

    #expect(criteria.matches(sizeBytes: 2_000, modified: old))
    #expect(criteria.matches(sizeBytes: 500, modified: old) == false)
    #expect(criteria.matches(sizeBytes: 2_000, modified: recent) == false)

    let sizeOnly = FinderCriteria(minimumBytes: 1_000, modifiedBeforeDays: 0)
    #expect(sizeOnly.matches(sizeBytes: 2_000, modified: recent))
}

/// A file with no readable modification date is reported rather than
/// dropped. Dropping it would fail in the direction that hides bytes.
@Test func criteriaKeepAFileWithNoModifiedDate() {
    let criteria = FinderCriteria(minimumBytes: 0, modifiedBeforeDays: 1)
    #expect(criteria.matches(sizeBytes: 10, modified: nil))
}

/// `FinderReport` already counted unreadable directories and already marked
/// floored sizes on individual rows; nothing put the two together, so no
/// caller could ask one question about whether the total was whole.
@Test func finderReportDerivesCompletenessFromWhatItAlreadyKnows() {
    let floored = FoundFile(
        path: URL(fileURLWithPath: "/tmp/bundle.app"), sizeBytes: 10,
        lastModified: nil, isBundle: true, partialRead: true)
    let exact = FoundFile(
        path: URL(fileURLWithPath: "/tmp/plain.bin"), sizeBytes: 10,
        lastModified: nil, isBundle: false)

    let report = FinderReport(
        files: [floored, exact], outcome: .finished,
        unreadableDirectoryCount: 3, unmeasuredCount: 0, duration: 0)

    #expect(report.completeness.unreadableDirectories == 3)
    #expect(report.completeness.flooredItems == 1)
    #expect(report.completeness.unmeasuredItems == 0)
    #expect(!report.completeness.isExact)
}

@Test func aWholeFinderRunReportsAnExactCompleteness() {
    let report = FinderReport(
        files: [FoundFile(
            path: URL(fileURLWithPath: "/tmp/plain.bin"), sizeBytes: 10,
            lastModified: nil, isBundle: false)],
        outcome: .finished, unreadableDirectoryCount: 0, unmeasuredCount: 0, duration: 0)

    #expect(report.completeness == .exact)
}

/// Stopping a find keeps what it has already found, which is what the Stop
/// button's own tooltip promises ("whatever it has already found stays on
/// screen"). What makes that honest rather than misleading is that the state
/// carrying those results is `.cancelled`, never `.completed`.
///
/// Cancels the current task from inside `onProgress` rather than racing
/// `finder.cancel()` from outside, so the count below is not a timing bet. An
/// earlier draft raced and asserted only `files.count >= 0`, which passed
/// against the still-discarding code.
@Test func aStoppedFindKeepsTheFilesItAlreadyFound() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<200 {
            try tree.file("dir-\(index)/file.bin", byteCount: 200_000)
        }

        final class ProgressCount: @unchecked Sendable { var calls = 0 }
        let progressCount = ProgressCount()

        let report = await FileFinder().run(
            root: root,
            criteria: FinderCriteria(minimumBytes: 1, modifiedBeforeDays: 0),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: PathGuard.Context(scanRoot: root, declaredPaths: []),
            onProgress: { _ in
                progressCount.calls += 1
                if progressCount.calls == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        #expect(report.outcome == .cancelled)
        // Genuinely partial: more than nothing (a discard on the cancelled
        // path would make this empty) and less than the full 200 (proving the
        // walk actually stopped rather than racing to completion first).
        #expect(report.files.count > 0)
        #expect(report.files.count < 200)
        #expect(!report.files.contains { $0.sizeBytes == 0 })
    }
}

/// A count that never reaches `ScanCompleteness` is a count nobody sees. The
/// seam stands in for the kernel here for the same reason the truncated-listing
/// test uses it: `getattrlistbulk` cannot be made to fail one entry on demand.
@Test func entriesTheKernelCouldNotDescribeReachTheCompletenessCount() async throws {
    try await withTempDirectory { root in
        let finder = FileFinder(listDirectory: { _ in
            BulkDirectoryListing(entries: [], readFailed: false, failedEntryCount: 2)
        })

        let report = await finder.run(
            root: root,
            criteria: allMatching(),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: context(for: root),
            onProgress: { _ in }
        )

        #expect(report.unreadableDirectoryCount == 2)
        #expect(report.completeness.unreadableDirectories == 2)
        #expect(report.completeness.isExact == false)
    }
}

/// First half of the defect: `FinderReport.completeness` hardcoded
/// `unmeasuredItems: 0`, justified by a comment asserting the finder "never has
/// unmeasured items" because it sizes as it discovers. Asserted directly on the
/// report, because the arm that produces a non-zero count — cancellation
/// landing inside a bundle's own walk — cannot be scheduled deterministically
/// from a test, and a flaky test is worse than an honest gap.
@Test func aFinderReportCarriesItsUnmeasuredCountIntoCompleteness() {
    let report = FinderReport(
        files: [], outcome: .cancelled,
        unreadableDirectoryCount: 0, unmeasuredCount: 3, duration: 0)

    #expect(report.completeness.unmeasuredItems == 3)
    #expect(report.completeness.isExact == false)
    #expect(report.completeness.caveat?.contains("not measured") == true)
}

/// Finding 04, second half, and the one that actually bites. Measured
/// a `chmod 000` bundle still reports `isPackage == true`, so the
/// finder does size it — and gets `bytes: 0, unreadablePaths: [<that
/// directory>], unmeasurableKind: false` back, because
/// a sealed directory's stat succeeds and only its enumeration fails. The
/// bundle then failed `criteria.matches` on size and was dropped with the
/// denial attached to it, so a find that could not read a whole application
/// bundle came back `.finished` and exact.
@Test func aBundleThatCouldNotBeReadIsCountedRatherThanSilentlyDropped() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("Sealed.app/Contents/blob.bin", byteCount: 400_000)
        let app = root.appending(path: "Sealed.app", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: app.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: app.path(percentEncoded: false))
        }

        let report = await FileFinder().run(
            root: root,
            criteria: FinderCriteria(minimumBytes: 1_024, modifiedBeforeDays: 0),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: PathGuard.Context(scanRoot: root, declaredPaths: []),
            onProgress: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.files.isEmpty)
        #expect(report.completeness.unreadableDirectories >= 1)
        #expect(report.completeness.isExact == false)
    }
}

/// The companion: an ordinary completed find must report nothing unmeasured and
/// nothing unreadable, or the caveat appears on every clean run and stops
/// meaning anything.
@Test func aCompletedFindOverAReadableTreeIsExact() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("big.bin", byteCount: 200_000)

        let report = await FileFinder().run(
            root: root,
            criteria: FinderCriteria(minimumBytes: 1_024, modifiedBeforeDays: 0),
            skipList: FinderSkipList(declaredPaths: []),
            guardContext: PathGuard.Context(scanRoot: root, declaredPaths: []),
            onProgress: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.files.count == 1)
        #expect(report.completeness.isExact)
    }
}
