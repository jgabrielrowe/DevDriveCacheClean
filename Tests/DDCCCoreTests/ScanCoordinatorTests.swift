import Testing
import Foundation
@testable import DDCCCore

@Test func endToEndScanFindsAMatchAndReportsFinished() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("dev/project/node_modules/pkg/index.js", byteCount: 16384)

        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()
        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.results.count == 1)
        #expect(report.results.first?.tier == .safe)
        #expect(report.results.first?.sizeBytes ?? 0 >= 16384)
        #expect(report.duration >= 0)
    }
}

/// The double-counting bug, end to end: the walk finds ~/.npm while an
/// explicit pattern finds ~/.npm/_cacache inside it.
@Test func overlappingPatternsProduceASingleResult() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("dev/.npm/_cacache/blob.bin", byteCount: 32768)

        let profiles = [
            ScanProfile(category: .nodeJS, patterns: [.dir(".npm", tier: .costly)]),
            ScanProfile(category: .packageCaches, patterns: [
                .path("~/dev/.npm/_cacache", tier: .costly),
            ]),
        ]
        let coordinator = ScanCoordinator()
        let report = await coordinator.run(
            root: root, profiles: profiles, home: root, onPhase: { _ in })

        #expect(report.results.count == 1)
        #expect(report.results.first?.path.lastPathComponent == "_cacache")
    }
}

@Test func cancelledScanReportsCancelledNotFinished() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<40 {
            try tree.file("dev/p-\(index)/node_modules/index.js", byteCount: 512)
        }
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()
        await coordinator.cancel()
        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })
        #expect(report.outcome == .cancelled)
    }
}

@Test func resolvingIsReportedBeforeMeasuring() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("dev/project/node_modules/index.js", byteCount: 8192)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])

        final class Box: @unchecked Sendable { var labels: [String] = [] }
        let box = Box()
        let coordinator = ScanCoordinator()
        _ = await coordinator.run(
            root: root, profiles: [profile], home: root,
            onPhase: { phase in
                switch phase {
                case .discovering: box.labels.append("discovering")
                case .resolving: box.labels.append("resolving")
                case .measuring: box.labels.append("measuring")
                }
            }
        )

        let resolvingIndex = try #require(box.labels.firstIndex(of: "resolving"))
        let measuringIndex = try #require(box.labels.firstIndex(of: "measuring"))
        #expect(resolvingIndex < measuringIndex)
    }
}

@Test func guardedPathsNeverReachResults() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        // One level below the scan root, so PathGuard refuses it.
        try tree.file("node_modules/index.js", byteCount: 8192)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()
        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })
        #expect(report.results.isEmpty)
    }
}

@Test func minimumSizeThresholdsFromProfilesAreHonoured() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("Caches/tiny/a.bin", byteCount: 1024)
        try tree.file("Caches/big/b.bin", byteCount: 400_000)

        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", minSize: 100_000, tier: .safe),
        ])
        let coordinator = ScanCoordinator()
        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.results.count == 1)
        #expect(report.results.first?.path.lastPathComponent == "big")
    }
}

/// `cancelScan()` cancels the surrounding `Task` synchronously, while a
/// cooperative caller that only checks `Task.isCancelled` (never calling
/// `coordinator.cancel()` at all) must still be honoured. Deterministic, not
/// a timing bet: `Task.cancel()` is called on the currently running task
/// before `run` is ever invoked, so `Task.isCancelled` is already `true` for
/// every check `run` makes, from the very first one.
@Test func runOnAnAlreadyCancelledTaskReportsCancelledWithNoResults() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("dev/project/node_modules/index.js", byteCount: 8192)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()

        withUnsafeCurrentTask { $0?.cancel() }

        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .cancelled)
        #expect(report.results.isEmpty)
    }
}

/// The gap this closes: `cancelScan()` cancels the surrounding
/// `Task` instantly, while the coordinator's own `isCancelled` arrives
/// separately through a MainActor-hopping `Task { await coordinator.cancel() }`.
/// `run`'s final decision must not consult that actor flag alone: a Stop press
/// during measuring would then reach `.finished` carrying whichever subset of
/// `results` had completed — a silently partial result set presented as a whole
/// scan, not merely a mislabeled one.
///
/// Deterministic, not a timing bet: `Task.cancel()` is called on the *current*
/// task (`withUnsafeCurrentTask`) synchronously from inside `onPhase` the
/// instant `.resolving` fires — `run` always emits that strictly before Stage
/// 3 starts, and there is no wall clock or thread hop involved in a task
/// cancelling itself. By the time `Measurer.measure` runs, `Task.isCancelled`
/// is unconditionally `true`; without the fix, `Measurer` would still finish
/// and `run` would still report `.finished` with all 5 results attached.
@Test func taskCancellationDuringMeasuringReportsCancelledNotFinished() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<5 {
            try tree.file("dev/p-\(index)/node_modules/index.js", byteCount: 4096)
        }
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()

        let report = await coordinator.run(
            root: root, profiles: [profile], home: root,
            onPhase: { phase in
                if case .resolving = phase {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        #expect(report.outcome == .cancelled)
        // `results` stays empty here not because of a discard on the
        // cancelled path, but because `Measurer`
        // itself never measures anything once `Task.isCancelled` is already
        // true when it starts, per the doc comment above. What matters here
        // is `completeness`: the 5 resolved candidates that never got
        // measured must show up as unmeasured, not vanish silently.
        #expect(report.results.isEmpty)
        #expect(report.completeness.unmeasuredItems > 0)
    }
}

/// The final return's `results:` field must not be gated on `cancelledNow`
/// (`results: cancelledNow ? [] : results`), which discards real measurements. `taskCancellationDuringMeasuringReportsCancelledNotFinished`
/// above cancels before `Measurer.measure` schedules its first child task, so
/// every candidate becomes `.skipped` and `results` is empty regardless of
/// that gate — it cannot tell "discarded" apart from "never measured".
///
/// This test cancels one step later, from inside the FIRST `.measuring`
/// progress callback. `Measurer.measure` appends a completed candidate's
/// `ScanResult` to `results` before calling `onProgress` for it, so by the
/// time this callback fires for `completed == 1`, that first result is
/// already in `results` — non-empty is guaranteed, not a timing bet.
@Test func taskCancellationAfterFirstMeasurementKeepsThatResult() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<20 {
            try tree.file("dev/p-\(index)/node_modules/index.js", byteCount: 4096)
        }
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()

        let report = await coordinator.run(
            root: root, profiles: [profile], home: root,
            onPhase: { phase in
                if case .measuring(let progress) = phase, progress.completed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        #expect(report.outcome == .cancelled)
        #expect(!report.results.isEmpty, "a partial set is only honest when the outcome says so")
    }
}

/// `ScanReport.completeness` must carry `unreadableDirectories` and
/// `flooredItems` on the finished path rather than zeros: `Measurer` already
/// surfaces both facts on every `ScanResult` via `unreadablePaths`/`partialRead`. A Caches run that could not read part
/// of the disk reported `completeness.isExact == true` regardless. This
/// fixture chmods a subdirectory to 0o000 (same technique as
/// `partialReadIsPropagatedToTheResult` in `MeasurerTests.swift`) so the
/// coordinator's own measuring stage produces a genuinely unreadable,
/// genuinely floored result — not a fixture that merely fails to exercise
/// the bug.
@Test func aCachesScanReportsDirectoriesItCouldNotRead() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("Caches/app/readable.bin", byteCount: 4096)
        let locked = try tree.directory("Caches/app/locked")
        try tree.file("Caches/app/locked/secret.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", minSize: 0, tier: .safe),
        ])
        let coordinator = ScanCoordinator()
        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.completeness.isExact == false)
        // A chmod-0o000 subdirectory drives both numbers off the same result:
        // it is named in `unreadablePaths`, which feeds `unreadableDirectories`,
        // and it sets `partialRead`, which feeds `flooredItems` — not just one
        // of the two.
        #expect(report.completeness.unreadableDirectories > 0)
        #expect(report.completeness.flooredItems > 0)
    }
}

/// the regression test (`RefusalSetTests.swift`,
/// `aDenialInsideASizedDirectoryDedupesAgainstTheWalksRefusalOfIt`) proved
/// that one sealed directory reached by both engines unions to a single
/// refusal — but it called `Measurer` and `FileScanner.walk` directly, so
/// nothing pinned the number the coordinator actually renders. This does,
/// through a real `ScanCoordinator.run(...)`: `~/cargo/registry` is
/// discovered by its `.path` pattern and genuinely sized (`readable.bin`
/// gives it real bytes), so the coordinator's measuring stage walks into
/// `sealed` and is refused there. Separately, the coordinator's own
/// `FileScanner.walk` over `root` descends into `registry` too — the
/// `.dir("node_modules", ...)` pattern exists only to keep `walk`'s lookup
/// non-empty so it actually traverses; `node_modules` is never present in
/// this fixture — and is refused by `sealed` on its own route. One sealed
/// directory, reached by both engines, must still render as one.
@Test func aRefusalReachedByBothEnginesRendersAsOne() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("cargo/registry/readable.bin", byteCount: 16_384)
        let sealed = try tree.directory("cargo/registry/sealed")
        try tree.file("cargo/registry/sealed/inner.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sealed.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .packageCaches, patterns: [
            .path("~/cargo/registry", tier: .safe),
            .dir("node_modules", tier: .safe),
        ])
        let coordinator = ScanCoordinator()
        let report = await coordinator.run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.results.count == 1)
        #expect((report.results.first?.sizeBytes ?? 0) > 0)
        // Exactly one, not `> 0`: `discoveryRefusals.union(measured.refusals)`
        // in `ScanCoordinator.run` collapses the same sealed directory
        // reached by both engines to a single refusal. Replacing that union
        // with `+` — the exact bug this plan removed, at the line that
        // renders it — makes this 2, and this is the only assertion in this
        // file that would catch it: every other assertion on this field
        // here is `> 0` or `>= 1`.
        #expect(report.completeness.unreadableDirectories == 1)
    }
}

@Test func scanStateIsActiveDuringBothStages() {
    #expect(ScanState.scanning(currentPath: "x", itemsFound: 0, bytesFound: 0).isActive)
    #expect(ScanState.measuring(progress: MeasureProgress(completed: 1, total: 2)).isActive)
    #expect(ScanState.idle.isActive == false)
    #expect(ScanState.cancelled(itemsFound: 0, bytesFound: 0, completeness: .exact).isActive == false)
    #expect(ScanState.completed(totalItems: 1, totalBytes: 1, duration: 1, completeness: .exact).isActive == false)
}

/// A stopped run has to be able to say what it found. `.cancelled` carried no
/// payload at all, which is why the Files list could show "No Files Found" for
/// a run that had found plenty before Stop was pressed.
@Test func aCancelledStateCarriesWhatWasFoundAndWhyItIsPartial() {
    let state = ScanState.cancelled(
        itemsFound: 1_204, bytesFound: 8_300_000_000,
        completeness: ScanCompleteness(
            unreadableDirectories: 3, flooredItems: 0, unmeasuredItems: 41))

    guard case .cancelled(let items, let bytes, let completeness) = state else {
        Issue.record("expected .cancelled")
        return
    }
    #expect(items == 1_204)
    #expect(bytes == 8_300_000_000)
    #expect(!completeness.isExact)
    #expect(state.isActive == false)
}

@Test func aCompletedStateCarriesItsCompleteness() {
    let state = ScanState.completed(
        totalItems: 2, totalBytes: 10, duration: 1,
        completeness: ScanCompleteness(
            unreadableDirectories: 1, flooredItems: 0, unmeasuredItems: 0))

    guard case .completed(_, _, _, let completeness) = state else {
        Issue.record("expected .completed")
        return
    }
    #expect(completeness.unreadableDirectories == 1)
}

/// End to end, and the reason this outranked everything
/// else on the list. Every other completeness defect produced an understated
/// total that announced itself. This one produced a FINISHED scan, green check,
/// no `+`, `isExact == true`, missing an entire category — a confident wrong
/// number, which is the single thing this project exists not to do.
///
/// Asserted on a completed run, not a cancelled one: `outcome == .cancelled`
/// already marks a run as a floor, so a cancelled fixture would pass even with
/// the defect fully present.
@Test func aCompletedScanThatCouldNotReadACategoryIsNotExact() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Caches/com.example.one")
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: caches.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: caches.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", tier: .safe),
        ])

        let report = await ScanCoordinator().run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.completeness.unreadableDirectories >= 1)
        #expect(report.completeness.isExact == false)
        // The caveat is the user-visible half; a count that reaches
        // `ScanCompleteness` but produces no sentence is still invisible.
        #expect(report.completeness.caveat?.contains("could not be read") == true)
    }
}

/// A clean tree must still come back exact, or the caveat fires on every scan
/// and stops carrying information.
@Test func aCleanCompletedScanIsExact() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("Caches/com.example.one/blob.bin", byteCount: 8192)

        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", tier: .safe),
        ])

        let report = await ScanCoordinator().run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.completeness.isExact)
        #expect(report.completeness.caveat == nil)
    }
}

/// A candidate that IS discovered, then turns out to be unreadable when it is
/// sized, must reach the same caveat. The
/// `.subdirs` fixture above cannot prove this — its parent fails during
/// discovery, so measuring never runs.
@Test func aCompletedScanWhoseCandidateCouldNotBeSizedIsNotExact() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("dev/Caches/blob.bin", byteCount: 8192)
        let caches = root.appending(path: "dev/Caches", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: caches.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: caches.path(percentEncoded: false))
        }

        // An `.absolutePath` pattern: the candidate's own stat succeeds through
        // a sealed directory, so discovery accepts it and measuring is what
        // discovers the refusal.
        //
        // Two levels below the root, not one. `PathGuard.evaluate` refuses a
        // plain directory that is not at least two levels below the scan root,
        // and this profile's path is not in
        // `ScanProfile.declaredAbsolutePaths`, so it does not get the
        // declared-path exemption. At `~/Caches` the candidate would be
        // refused during resolution and never reach measuring at all.
        let profile = ScanProfile(category: .appCaches, patterns: [
            .path("~/dev/Caches", tier: .safe),
        ])

        let report = await ScanCoordinator().run(
            root: root, profiles: [profile], home: root, onPhase: { _ in })

        #expect(report.outcome == .finished)
        #expect(report.results.isEmpty)
        #expect(report.completeness.unreadableDirectories >= 1)
        #expect(report.completeness.isExact == false)
    }
}
