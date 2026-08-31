import Foundation

public enum ScanPhase: Sendable {
    case discovering(path: String)
    case resolving
    case measuring(MeasureProgress)
}

public struct ScanReport: Sendable {
    public let results: [ScanResult]
    public let outcome: ScanOutcome
    public let duration: TimeInterval
    /// Required, never defaulted: a construction site that has not thought
    /// about completeness should not compile.
    public let completeness: ScanCompleteness

    public init(
        results: [ScanResult], outcome: ScanOutcome, duration: TimeInterval,
        completeness: ScanCompleteness
    ) {
        self.results = results
        self.outcome = outcome
        self.duration = duration
        self.completeness = completeness
    }
}

/// Runs discovery, resolution, and measuring in order, and owns cancellation.
///
/// Resolution sits between the other two because the deduplication policy needs
/// the complete candidate set: discovery emits `~/.npm/_cacache` long before the
/// walk reaches `~/.npm`, so which one survives cannot be decided while results
/// are still streaming.
public actor ScanCoordinator {
    private let scanner = FileScanner()
    private var isCancelled = false

    public init() {}

    public func cancel() async {
        isCancelled = true
        await scanner.cancel()
    }

    public func run(
        root: URL,
        profiles: [ScanProfile] = ScanProfile.all,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        onPhase: @Sendable @escaping (ScanPhase) -> Void
    ) async -> ScanReport {
        let start = Date()

        // Stage 1 — discovery. Cheap enumeration, no sizing.
        var candidates: [Candidate] = []
        let discovery = await scanner.discoverPathPatterns(profiles: profiles, home: home)
        candidates += discovery.candidates

        let walkResult = await scanner.walk(
            root: root, profiles: profiles,
            onProgress: { path in onPhase(.discovering(path: path)) }
        )
        candidates += walkResult.candidates

        // Both stages of discovery, before either return can drop them. A
        // refusal here means bytes exist that no row will ever represent, so it
        // must survive the cancelled path as well as the finished one.
        //
        // Unioned, not added. Discovery and the walk traverse overlapping
        // territory — both reach `~/.cargo/registry` — so one refused
        // directory would otherwise render as "2 folders could not be read".
        // See `RefusalSet`.
        let discoveryRefusals = discovery.refusals.union(walkResult.refusals)

        if isCancelled || Task.isCancelled || walkResult.outcome == .cancelled {
            return ScanReport(
                results: [], outcome: .cancelled,
                duration: Date().timeIntervalSince(start),
                // Nothing reached measuring, so every candidate is unmeasured.
                // Pre-dedup, so this count is a ceiling: it can overstate how
                // many rows would have appeared, never understate. Discovery's
                // refusals are real regardless of cancellation — a directory it
                // could not list is missing from `candidates` either way — so
                // they are carried here too, not hardcoded to zero.
                completeness: ScanCompleteness(
                    unreadableDirectories: discoveryRefusals.count, flooredItems: 0,
                    unmeasuredItems: candidates.count)
            )
        }

        // Stage 2 — resolution. Guard, then dedup, then containment collapse.
        onPhase(.resolving)
        let context = PathGuard.Context(
            scanRoot: root, declaredPaths: ScanProfile.declaredAbsolutePaths)
        let resolved = CandidateResolver.resolve(candidates, in: context)

        // Stage 3 — measuring. Survivors only, so progress is a real fraction.
        let measured = await Measurer.measure(
            resolved,
            minimumSizes: Self.minimumSizes(for: profiles, home: home),
            onProgress: { progress in onPhase(.measuring(progress)) }
        )
        let results = measured.results

        // `cancelScan()` cancels the surrounding `Task` immediately, but this
        // actor's own `isCancelled` arrives separately via a MainActor-hopping
        // `Task { await coordinator.cancel() }`, which can still be in flight
        // here — so the outcome must consult both `isCancelled` and
        // `Task.isCancelled`, not just one. `results` is kept either way:
        // `completeness.unmeasuredItems` says how many rows are missing, so a
        // stopped scan can show its partial results without passing them off
        // as a whole one.
        let cancelledNow = isCancelled || Task.isCancelled
        return ScanReport(
            results: results,
            outcome: cancelledNow ? .cancelled : .finished,
            duration: Date().timeIntervalSince(start),
            completeness: ScanCompleteness(
                // Derived from `results` regardless of cancellation — dropping
                // these on the cancelled path would understate incompleteness
                // exactly when it matters most.
                //
                // Two sources, both path-identified: what discovery could not
                // read, and what measuring could not read — the latter now
                // including denials met inside directories that were
                // successfully sized. A candidate refused during discovery is
                // counted here ONCE and never also as `unmeasuredItems` — it
                // was never discovered, so it was never "discovered but not
                // sized".
                //
                // Unioned rather than added: the two overlap, so summing them
                // would report one refused directory as two. `Measurer` folds
                // its own denials into `measured.refusals` by path, so taking
                // it whole is correct and taking it apart would not be.
                unreadableDirectories: discoveryRefusals.union(measured.refusals).count,
                flooredItems: results.filter(\.partialRead).count,
                unmeasuredItems: measured.unmeasured)
        )
    }

    /// Byte thresholds declared by enumeration patterns, keyed by the path each
    /// enumeration will produce. Applied after sizing, because a threshold
    /// cannot be evaluated before a size exists.
    ///
    /// Keys route through `Candidate.normalizedPathKey(for:)` — the single
    /// place that decides what a path looks like as a comparison key — rather
    /// than a hand-rolled derivation, so this can never silently disagree with
    /// the `pathKey` `Measurer` looks the threshold up by.
    private static func minimumSizes(
        for profiles: [ScanProfile], home: URL
    ) -> [String: Int64] {
        var thresholds: [String: Int64] = [:]

        func expand(_ raw: String) -> URL {
            guard raw.hasPrefix("~") else {
                return URL(fileURLWithPath: raw).standardizedFileURL
            }
            return home.appending(path: String(raw.dropFirst(2)), directoryHint: .isDirectory)
                .standardizedFileURL
        }

        func children(of parent: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        }

        for profile in profiles {
            for pattern in profile.patterns {
                // Exhaustive over every `Pattern.Kind` case, deliberately
                // with no `default:`, so a new kind that should carry a
                // threshold can't silently get none — adding a case to
                // `Kind` forces a decision here.
                switch pattern.kind {
                case .directoryName, .absolutePath:
                    continue
                case .subdirectories(let parentRaw, let minSize):
                    guard minSize > 0 else { continue }
                    for child in children(of: expand(parentRaw)) {
                        thresholds[Candidate.normalizedPathKey(for: child)] = minSize
                    }
                case .childSubpath(let parentRaw, let subpath, let minSize):
                    guard minSize > 0 else { continue }
                    for child in children(of: expand(parentRaw)) {
                        let target = child.appending(path: subpath, directoryHint: .isDirectory)
                        thresholds[Candidate.normalizedPathKey(for: target)] = minSize
                    }
                // Thresholded like `.subdirectories`: the retention filter runs
                // in `FileScanner`, and a version it retained simply never
                // becomes a candidate for this threshold to apply to.
                // Thresholded like `.subdirectories` for the same reason as
                // `.toolchainVersions` below: the retention filter runs in
                // `FileScanner`, so a version it kept never becomes a candidate
                // for this threshold to apply to.
                case .engineVersions(let parentRaw, _, let minSize):
                    guard minSize > 0 else { continue }
                    for child in children(of: expand(parentRaw)) {
                        thresholds[Candidate.normalizedPathKey(for: child)] = minSize
                    }
                case .toolchainVersions(let parentRaw, _, _, let minSize):
                    guard minSize > 0 else { continue }
                    for child in children(of: expand(parentRaw)) {
                        thresholds[Candidate.normalizedPathKey(for: child)] = minSize
                    }
                }
            }
        }

        return thresholds
    }
}
