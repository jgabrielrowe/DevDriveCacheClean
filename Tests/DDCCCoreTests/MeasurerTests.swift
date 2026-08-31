import Testing
import Foundation
@testable import DDCCCore

private func resolved(
    _ url: URL,
    tier: RemovalTier = .safe,
    verdict: PathGuard.Verdict = .allowed,
    category: CleanCategory = .appCaches
) -> ResolvedCandidate {
    ResolvedCandidate(
        candidate: Candidate(
            path: url, category: category, tier: tier,
            removability: verdict == .lockedInformational ? .requiresPrivileges : .removable,
            specificity: .explicit,
            displayName: "\(category.rawValue): \(url.lastPathComponent)"
        ),
        verdict: verdict
    )
}

@Test func measuresEachSurvivorAndCarriesMetadata() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let dir = try tree.directory("cache")
        try tree.file("cache/blob.bin", byteCount: 8192)

        let results = await Measurer.measure(
            [resolved(dir, tier: .costly)], minimumSizes: [:], onProgress: { _ in }).results

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.sizeBytes >= 8192)
        #expect(result.tier == .costly)
        #expect(result.isDeletable == true)
        #expect(result.partialRead == false)
    }
}

@Test func zeroByteCandidatesAreDropped() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let empty = try tree.directory("empty")
        let results = await Measurer.measure(
            [resolved(empty)], minimumSizes: [:], onProgress: { _ in }).results
        #expect(results.isEmpty)
    }
}

@Test func minimumSizeThresholdIsAppliedAfterSizing() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let small = try tree.directory("small")
        try tree.file("small/tiny.bin", byteCount: 1024)
        let large = try tree.directory("large")
        try tree.file("large/big.bin", byteCount: 200_000)

        let results = await Measurer.measure(
            [resolved(small), resolved(large)],
            minimumSizes: [
                small.standardizedFileURL.path(percentEncoded: false): 100_000,
                large.standardizedFileURL.path(percentEncoded: false): 100_000,
            ],
            onProgress: { _ in }
        ).results

        #expect(results.count == 1)
        #expect(results.first?.path.lastPathComponent == "large")
    }
}

@Test func lockedCandidatesAreMeasuredAndMarkedUndeletable() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let locked = try tree.directory("locked")
        try tree.file("locked/blob.bin", byteCount: 4096)

        let results = await Measurer.measure(
            [resolved(locked, verdict: .lockedInformational)],
            minimumSizes: [:], onProgress: { _ in }).results

        #expect(results.count == 1)
        #expect(results.first?.isDeletable == false)
        #expect(results.first?.sizeBytes ?? 0 >= 4096)
    }
}

@Test func progressReachesTotalAndIsDeterminate() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        var candidates: [ResolvedCandidate] = []
        for index in 0..<5 {
            let dir = try tree.directory("cache-\(index)")
            try tree.file("cache-\(index)/blob.bin", byteCount: 4096)
            candidates.append(resolved(dir))
        }

        final class Box: @unchecked Sendable {
            var updates: [MeasureProgress] = []
        }
        let box = Box()

        _ = await Measurer.measure(candidates, minimumSizes: [:], onProgress: { progress in
            box.updates.append(progress)
        })

        #expect(box.updates.isEmpty == false)
        #expect(box.updates.allSatisfy { $0.total == 5 })
        #expect(box.updates.map(\.completed).max() == 5)
    }
}

@Test func progressFractionIsZeroWhenTotalIsZero() {
    #expect(MeasureProgress(completed: 0, total: 0).fraction == 0)
}

@Test func progressFractionIsOneWhenComplete() {
    #expect(MeasureProgress(completed: 4, total: 4).fraction == 1)
}

@Test func partialReadIsPropagatedToTheResult() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let dir = try tree.directory("cache")
        try tree.file("cache/readable.bin", byteCount: 4096)
        let locked = try tree.directory("cache/locked")
        try tree.file("cache/locked/secret.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
        }

        let results = await Measurer.measure(
            [resolved(dir)], minimumSizes: [:], onProgress: { _ in }).results

        #expect(results.first?.partialRead == true)
        // The path, not a tally: this is what lets the coordinator collapse
        // this denial against the same directory the walk was refused.
        #expect(results.first?.unreadablePaths == [Candidate.normalizedPathKey(for: locked)])
    }
}

@Test func emptyInputProducesNoResultsAndNoCrash() async {
    let results = await Measurer.measure([], minimumSizes: [:], onProgress: { _ in }).results
    #expect(results.isEmpty)
}

@Test func resultsAreSortedLargestFirst() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let small = try tree.directory("small")
        try tree.file("small/a.bin", byteCount: 4096)
        let large = try tree.directory("large")
        try tree.file("large/b.bin", byteCount: 400_000)

        let results = await Measurer.measure(
            [resolved(small), resolved(large)], minimumSizes: [:], onProgress: { _ in }).results

        #expect(results.first?.path.lastPathComponent == "large")
    }
}

/// The Caches equivalent of the FileFinder tie-break: three directories of
/// identical size, given to `measure` in an order that is not sorted, must
/// come back in path order and identically on a second call.
@Test func equalSizedResultsAreOrderedByPathNotDiscoveryOrder() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let c = try tree.directory("c-dir")
        try tree.file("c-dir/blob.bin", byteCount: 4096)
        let a = try tree.directory("a-dir")
        try tree.file("a-dir/blob.bin", byteCount: 4096)
        let b = try tree.directory("b-dir")
        try tree.file("b-dir/blob.bin", byteCount: 4096)

        let candidates = [resolved(c), resolved(a), resolved(b)]

        let names = { () async -> [String] in
            await Measurer.measure(candidates, minimumSizes: [:], onProgress: { _ in })
                .results.map(\.path.lastPathComponent)
        }

        let first = await names()
        #expect(first == ["a-dir", "b-dir", "c-dir"])
        // Twice, because an order that happens to match on one run proves
        // nothing about the next — task-group completion order is not fixed.
        #expect(await names() == first)
    }
}

/// A task group entry that sees cancellation returns nil and vanishes from
/// `results`. Without a count of those, a scan stopped during measuring is
/// indistinguishable from a smaller scan that finished — which is the whole
/// defect this plan exists to close, one layer down.
@Test func measurerReportsHowManyCandidatesItNeverSized() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("a.bin", byteCount: 2_048)
        try tree.file("b.bin", byteCount: 2_048)

        let candidates = [
            resolved(root.appending(path: "a.bin")),
            resolved(root.appending(path: "b.bin")),
        ]

        let outcome = await withTaskGroup(of: MeasureOutcome.self) { group -> MeasureOutcome in
            group.addTask {
                await Measurer.measure(candidates, minimumSizes: [:], onProgress: { _ in })
            }
            group.cancelAll()
            return await group.next()!
        }

        // Every candidate either produced a result or was counted as unmeasured.
        // Asserting the sum rather than a fixed split, because how many tasks
        // start before cancellation lands is genuinely nondeterministic.
        #expect(outcome.results.count + outcome.unmeasured == candidates.count)
    }
}

/// The uncancelled path must report zero unmeasured, or the caveat would appear
/// on every clean scan and stop meaning anything.
@Test func aCompleteMeasurementReportsNothingUnmeasured() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("a.bin", byteCount: 2_048)

        let outcome = await Measurer.measure(
            [resolved(root.appending(path: "a.bin"))],
            minimumSizes: [:], onProgress: { _ in })

        #expect(outcome.unmeasured == 0)
        #expect(outcome.results.count == 1)
    }
}

/// An empty directory and a below-threshold directory are both fully measured
/// and deliberately excluded — not incompleteness. Counting them as
/// `unmeasured` would make the caveat appear on every ordinary scan that uses
/// the size-threshold feature, since exclusion by threshold is the common
/// case, not the exceptional one.
@Test func excludedCandidatesDoNotCountAsUnmeasured() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let empty = try tree.directory("empty")
        let small = try tree.directory("small")
        try tree.file("small/tiny.bin", byteCount: 1024)

        let outcome = await Measurer.measure(
            [resolved(empty), resolved(small)],
            minimumSizes: [
                small.standardizedFileURL.path(percentEncoded: false): 100_000
            ],
            onProgress: { _ in })

        #expect(outcome.results.isEmpty)
        #expect(outcome.unmeasured == 0)
    }
}

/// The defect in the shape it actually takes on disk. Measured
/// a `chmod 000` directory does NOT make `SizeCalculator` throw.
/// Its stat succeeds, the enumerator is created, it yields nothing, and the
/// error handler fires once — so the result is
/// `SizeMeasurement(bytes: 0, unreadablePaths: [<that directory>],
/// unmeasurableKind: false)`. `makeResult` then read
/// `bytes > 0` as false and returned `.excluded`, a category explicitly
/// documented as "fully measured, then deliberately filtered". The denial went
/// with it, and a scan that could not read a whole category still reported
/// itself exact.
///
/// The rule: if no row is produced and something was refused, that is an
/// unreadable path, not an exclusion.
@Test func aCandidateThatWasRefusedProducesNoRowAndIsCountedAsUnreadable() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let refused = try tree.directory("refused")
        try tree.file("refused/inner.bin", byteCount: 8192)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: refused.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: refused.path(percentEncoded: false))
        }

        let outcome = await Measurer.measure(
            [resolved(refused)], minimumSizes: [:], onProgress: { _ in })

        #expect(outcome.results.isEmpty)
        #expect(outcome.refusals.count == 1)
        #expect(outcome.unmeasured == 0)
    }
}

/// Two refusals inside one candidate must stay two, and must be named by the
/// directories that actually refused us.
///
/// `noRow()` must keep `measurement.unreadablePaths` rather than answering
/// with the candidate's own key whenever the read was partial. A fixture with
/// exactly ONE sealed directory cannot tell the two apart — "keep the
/// measurement's set" and "collapse it to the candidate" give the identical
/// number. Two sealed children separate them: the substitution
/// answers 1, the truth is 2.
///
/// The two seals are siblings, deliberately. Nested ones would be absorbed into
/// each other by `RefusalSet`'s ancestor collapse — legitimately — and the
/// count would be 1 either way, pinning nothing. The parent itself is readable
/// and holds no files of its own, so it produces no row and takes `noRow()`.
@Test func twoRefusalsInsideOneCandidateAreCountedAsTwoAndNamedByTheirOwnPaths() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let parent = try tree.directory("parent")
        let firstSeal = try tree.directory("parent/sealedOne")
        try tree.file("parent/sealedOne/inner.bin", byteCount: 8192)
        let secondSeal = try tree.directory("parent/sealedTwo")
        try tree.file("parent/sealedTwo/inner.bin", byteCount: 8192)
        for seal in [firstSeal, secondSeal] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: seal.path(percentEncoded: false))
        }
        defer {
            for seal in [firstSeal, secondSeal] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: seal.path(percentEncoded: false))
            }
        }

        let outcome = await Measurer.measure(
            [resolved(parent)], minimumSizes: [:], onProgress: { _ in })

        // No row: the only bytes in `parent` sit behind the two seals.
        #expect(outcome.results.isEmpty)
        #expect(outcome.unmeasured == 0)
        // Two distinct directories refused us, so "N folders could not be read"
        // must say two.
        #expect(outcome.refusals.count == 2)
        // And it must name the seals, not the readable parent that was walked
        // successfully — naming `parent` would report a directory we read as
        // one we could not.
        #expect(outcome.refusals.paths == [
            Candidate.normalizedPathKey(for: firstSeal),
            Candidate.normalizedPathKey(for: secondSeal),
        ])
    }
}

/// The other refusal shape, which does throw: a candidate whose PARENT is
/// sealed. Measured: to raise `NSCocoaErrorDomain` 257
/// (`NSFileReadNoPermissionError`), which is the `.unmeasurable` path. Both
/// shapes must count, and they reach the counter by different routes — a fix
/// that handles one is half a fix.
@Test func aCandidateBehindASealedParentIsCountedAsUnreadable() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Vault/Secret")
        let vault = root.appending(path: "Vault", directoryHint: .isDirectory)
        let secret = vault.appending(path: "Secret", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: vault.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: vault.path(percentEncoded: false))
        }

        let outcome = await Measurer.measure(
            [resolved(secret)], minimumSizes: [:], onProgress: { _ in })

        #expect(outcome.results.isEmpty)
        #expect(outcome.refusals.count == 1)
        #expect(outcome.unmeasured == 0)
    }
}

/// The fallback in `noRow()`, at the one shape that actually needs it.
///
/// A symlink candidate is `unmeasurableKind`: nothing refused us, so
/// `unreadablePaths` is empty, yet the read still reads as partial and produces
/// no row. There is no interior path to name, so the candidate's own key is the
/// only identity available — drop the fallback and this candidate vanishes from
/// the tallies entirely, which is a behaviour change nothing else would catch.
///
/// It is counted as a refusal even though nothing refused us. That is
/// deliberate and pre-existing: correcting the label is a follow-up, not
/// done here.
@Test func anUnmeasurableKindStillCountsThroughTheCandidatesOwnKey() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("realDirectory")
        try tree.file("realDirectory/inside.bin", byteCount: 8192)
        let link = try tree.symlink("linkToDirectory", to: target)

        let outcome = await Measurer.measure(
            [resolved(link)], minimumSizes: [:], onProgress: { _ in })

        #expect(outcome.results.isEmpty)
        #expect(outcome.unmeasured == 0)
        #expect(outcome.refusals.paths == [Candidate.normalizedPathKey(for: link)])
    }
}

/// The companion property, and the reason `excludedCandidatesDoNotCountAsUnmeasured`
/// above is not enough on its own: a genuinely empty directory and a
/// below-threshold one are fully measured and deliberately dropped, and must
/// leave BOTH new counters at zero. Without this, the fix for the two tests
/// above could be "count everything that produced no row", which would put a
/// caveat on every ordinary scan.
@Test func excludedCandidatesCountAsNeitherUnmeasuredNorUnreadable() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let empty = try tree.directory("empty")
        let small = try tree.directory("small")
        try tree.file("small/tiny.bin", byteCount: 1024)

        let outcome = await Measurer.measure(
            [resolved(empty), resolved(small)],
            minimumSizes: [
                small.standardizedFileURL.path(percentEncoded: false): 100_000
            ],
            onProgress: { _ in })

        #expect(outcome.results.isEmpty)
        #expect(outcome.unmeasured == 0)
        #expect(outcome.refusals.count == 0)
    }
}

/// `Measurer.makeResult`'s `.cancelled` arm, reached when `SizeCalculator`
/// itself reports cancellation from mid-walk — distinct from
/// `measurerReportsHowManyCandidatesItNeverSized` above, which only ever
/// exercises the pre-task `Task.isCancelled` short-circuit in `measure`'s
/// `addTask` closure, since that guard returns before `SizeCalculator` is
/// ever called. Reaching the mid-walk arm needs a race that isn't
/// schedulable reliably in a fast suite, so it's reached here through the
/// `sizeOf` seam instead: a fake `SizeOutcome` producer that always reports
/// `.cancelled`, so the arm fires deterministically without any real
/// cancellation, timing, or fixture size at all.
///
/// The `refusals.count == 0` assertion is the load-bearing one: cancellation
/// and refusal are different kinds of incompleteness (see `EntryOutcome`),
/// and a mutant that reports `.cancelled` as `.unreadable(path:)` instead of
/// `.skipped` would still pass an `unmeasured`-only check.
@Test func aMidWalkCancellationIsCountedAsUnmeasuredNeverAsRefused() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("a.bin", byteCount: 2_048)

        let outcome = await Measurer.measure(
            [resolved(root.appending(path: "a.bin"))],
            minimumSizes: [:],
            onProgress: { _ in },
            sizeOf: { _ in .cancelled }
        )

        #expect(outcome.results.isEmpty)
        #expect(outcome.unmeasured == 1)
        #expect(outcome.refusals.count == 0)
    }
}

/// The mixed case: a mid-walk cancellation is not "all or nothing" — a
/// candidate that genuinely measures alongside one that gets `.cancelled`
/// from `sizeOf` must still show up in `results`, and the cancelled one must
/// not drag it down or get conflated with it.
@Test func aMixedBatchCountsOnlyTheCancelledCandidateAsUnmeasured() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("cancelled.bin", byteCount: 2_048)
        try tree.file("measured.bin", byteCount: 2_048)
        let cancelledURL = root.appending(path: "cancelled.bin")
        let measuredURL = root.appending(path: "measured.bin")

        let outcome = await Measurer.measure(
            [resolved(cancelledURL), resolved(measuredURL)],
            minimumSizes: [:],
            onProgress: { _ in },
            sizeOf: { url in
                url.lastPathComponent == "cancelled.bin"
                    ? .cancelled
                    : SizeCalculator.measure(at: url)
            }
        )

        #expect(outcome.unmeasured == 1)
        #expect(outcome.results.count == 1)
        #expect(outcome.results.first?.path.lastPathComponent == "measured.bin")
        #expect(outcome.refusals.count == 0)
    }
}

/// `Measurer` folded each refused candidate into its accumulator with a
/// `union`, and every `union` rebuilt and re-collapsed the entire set. Fixing
/// `collapsingDescendants` alone does not fix that: the collapse is cheap now,
/// but doing it once per refusal still grows with the square of the refusal
/// count. Measured with the fast collapse in place, 5,000 refusals accumulated
/// this way still took ~12s.
///
/// Driven through the `sizeOf` seam rather than thousands of `chmod 000`
/// directories, so the cost measured is the accumulation and nothing else.
@Test(.timeLimit(.minutes(1)))
func manyRefusedCandidatesDoNotCostTheSquareOfTheirCount() async throws {
    let root = URL(fileURLWithPath: "/Users/x/Library/Caches")
    let candidates = (0..<20_000).map { resolved(root.appending(path: "app-\($0)/data")) }

    let outcome = await Measurer.measure(
        candidates,
        minimumSizes: [:],
        onProgress: { _ in },
        sizeOf: { _ in .unmeasurable }
    )

    // Siblings, so none absorbs another and every refusal is its own hole.
    #expect(outcome.refusals.count == 20_000)
    #expect(outcome.results.isEmpty)
}

// MARK: - Bytes the tree does not own

/// The figure has to survive the measurer, or the row cannot explain why it is
/// smaller than the folder looks in Finder.
@Test func withheldBytesReachTheRow() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let store = try tree.file("store/payload.bin", byteCount: 200_000)
        let project = try tree.directory("project")
        try tree.file("project/own.bin", byteCount: 200_000)
        try tree.hardLink("project/linked.bin", to: store)

        let results = await Measurer.measure(
            [resolved(project)], minimumSizes: [:], onProgress: { _ in }).results

        let result = try #require(results.first)
        #expect(result.sizeBytes >= 200_000)
        #expect(result.sizeBytes < 400_000)
        #expect(result.sharedBytesWithheld >= 200_000)
    }
}

/// A `node_modules` linked entirely into a store frees nothing, so it measures
/// zero — and zero-byte candidates are dropped. Dropping it would delete the
/// only place the explanation could appear, leaving a folder the user can see
/// in Finder simply missing from the scan with no reason given. It keeps its
/// row, at zero, carrying the number that explains it.
@Test func anItemWhollyLinkedElsewhereKeepsItsRow() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let store = try tree.file("store/payload.bin", byteCount: 200_000)
        let project = try tree.directory("project")
        try tree.hardLink("project/linked.bin", to: store)

        let results = await Measurer.measure(
            [resolved(project)], minimumSizes: [:], onProgress: { _ in }).results

        let result = try #require(results.first)
        #expect(result.sizeBytes == 0)
        #expect(result.sharedBytesWithheld >= 200_000)
    }
}

/// The minimum-size threshold filters on what removing the item would free, so
/// an item under the threshold stays under it however much it withholds. What
/// must not happen is the withheld bytes quietly counting towards the minimum.
@Test func withheldBytesDoNotSatisfyAMinimumSizeThreshold() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let store = try tree.file("store/payload.bin", byteCount: 400_000)
        let project = try tree.directory("project")
        try tree.file("project/own.bin", byteCount: 4096)
        try tree.hardLink("project/linked.bin", to: store)

        let results = await Measurer.measure(
            [resolved(project)],
            minimumSizes: [Candidate.normalizedPathKey(for: project): 200_000],
            onProgress: { _ in }).results

        #expect(results.isEmpty)
    }
}
