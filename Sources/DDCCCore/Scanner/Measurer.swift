import Foundation

/// How far through the measuring stage the scan is.
///
/// Determinate because the survivor count is known before measuring begins —
/// the reason discovery and measuring are separate stages.
public struct MeasureProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

/// What one measuring pass produced, and what it did not.
public struct MeasureOutcome: Sendable {
    public let results: [ScanResult]
    /// Candidates that were never sized, because cancellation reached them —
    /// either before their task ran, or partway through their directory walk.
    /// They are absent from `results` rather than present with a zero size, so
    /// nothing downstream can notice them without this number.
    public let unmeasured: Int
    /// Candidates that were refused, not cancelled, carrying identity where it
    /// exists. A candidate whose walk ran, hit denied entries and produced no
    /// row contributes each of those entries by name — a directory sealed
    /// against us is named as itself, since the enumerator's errorHandler fires
    /// on the root it cannot open — so the same directory the walk also failed
    /// to enter can be unioned down to one refusal, not summed into two, and
    /// two sealed children of one readable directory stay two. A candidate
    /// whose own metadata could not be read has no interior path to name and
    /// is identified by its own. A candidate that WAS sized, but hit a denial
    /// somewhere *inside* the directory it successfully measured, contributes
    /// that denial's own path — the sealed child, not the candidate — so it
    /// deduplicates the same way everything else does.
    /// Distinct from `unmeasured`, which is about cancellation, not refusal.
    public let refusals: RefusalSet

    public init(results: [ScanResult], unmeasured: Int, refusals: RefusalSet) {
        self.results = results
        self.unmeasured = unmeasured
        self.refusals = refusals
    }
}

/// Sizes resolved candidates concurrently and turns them into `ScanResult`s.
public enum Measurer {

    /// - Parameter minimumSizes: per-path byte thresholds from `.subdirectories`
    ///   and `.childSubpath` patterns. Applied after sizing, since a threshold
    ///   cannot be evaluated before a size exists.
    /// - Parameter sizeOf: how a single candidate's size is obtained. Defaulted
    ///   to the real `SizeCalculator`, so every existing caller is unaffected;
    ///   a test can substitute a fake to reach `makeResult`'s `.cancelled` arm
    ///   deterministically, which a real mid-walk race is not schedulable
    ///   reliably enough to hit in a fast suite.
    public static func measure(
        _ resolved: [ResolvedCandidate],
        minimumSizes: [String: Int64],
        onProgress: @Sendable @escaping (MeasureProgress) -> Void,
        sizeOf: @Sendable @escaping (URL) -> SizeOutcome = SizeCalculator.measure(at:)
    ) async -> MeasureOutcome {
        let total = resolved.count
        guard total > 0 else { return MeasureOutcome(results: [], unmeasured: 0, refusals: .none) }

        // `candidate.pathKey` is standardized slash-free, but callers
        // building this map from a raw directory `URL`'s path can end up
        // with a trailing slash (a directory-hinted URL keeps it through
        // `standardizedFileURL`). Route every key through the same
        // normalization `Candidate` uses so that difference can never
        // silently swallow a threshold.
        let normalizedMinimums = Self.normalizedKeys(minimumSizes)

        var results: [ScanResult] = []
        results.reserveCapacity(total)
        var completed = 0
        var unmeasured = 0
        // Gathered raw and turned into a `RefusalSet` once at the end.
        // Folding each refusal in with `union` re-collapsed the whole set every
        // time, so a scan refused thousands of candidates spent minutes
        // rebuilding the same answer.
        var refusedPaths: Set<String> = []

        await withTaskGroup(of: EntryOutcome.self) { group in
            for entry in resolved {
                group.addTask {
                    // A short-circuit, not a correctness branch, and
                    // deliberately not covered by a test. `SizeCalculator`
                    // checks cancellation itself before walking anything
                    // (`SizeCalculator.swift`), returning `.cancelled`, which
                    // `makeResult` maps to this same `.skipped`. Deleting this
                    // line therefore changes no observable outcome — it only
                    // makes each already-cancelled candidate construct an
                    // enumerator before giving the same answer. What it buys is
                    // cancel-path responsiveness across every resolved
                    // candidate at once, which is why it stays.
                    //
                    // It survives mutation testing for that reason, and that is
                    // expected rather than a coverage gap: no test driving the
                    // real sizer can distinguish its presence. A fake `sizeOf`
                    // that ignored cancellation could, but would only be
                    // pinning the fake's own behaviour.
                    if Task.isCancelled { return .skipped }
                    return makeResult(for: entry, minimumSizes: normalizedMinimums, sizeOf: sizeOf)
                }
            }

            for await outcome in group {
                completed += 1
                onProgress(MeasureProgress(completed: completed, total: total))
                switch outcome {
                case .measured(let result):
                    results.append(result)
                case .excluded:
                    // Fully measured, then filtered out by the caller's own
                    // threshold or a zero-byte size. Not incompleteness —
                    // exclusion by threshold is the common case for an
                    // ordinary clean scan, not the exceptional one.
                    break
                case .skipped:
                    // Never sized: cancellation before the task ran, or
                    // cancellation partway through the walk.
                    unmeasured += 1
                case .unreadable(let paths):
                    // Produced no row, and was refused something on the way.
                    // Identified by path, so a refusal `walk` also hit for
                    // these same directories unions down to one each, not two.
                    // Unioned rather than inserted: one candidate can be
                    // refused several distinct directories, and each is its own
                    // hole in the total.
                    refusedPaths.formUnion(paths)
                }
            }
        }

        // Denials met *inside* a directory that was sized still name the
        // directory that refused us, so they union and collapse like any
        // other refusal. Naming them is what makes `unreadableDirectories`
        // an exact count rather than a floor.
        for result in results {
            refusedPaths.formUnion(result.unreadablePaths)
        }

        return MeasureOutcome(
            results: results.inDisplayOrder(),
            unmeasured: unmeasured,
            refusals: RefusalSet(paths: refusedPaths)
        )
    }

    /// Runs each key through `Candidate.normalizedPathKey(for:)`, so a
    /// threshold keyed by a raw directory `URL`'s path still matches
    /// `Candidate.pathKey`, which never carries a trailing slash.
    ///
    /// If two spellings of the same path collide onto one normalized key,
    /// keeps the larger threshold — the stricter reading — rather than let
    /// dictionary insertion order pick a winner silently, so a duplicate
    /// entry can only make a candidate harder to keep, never easier.
    private static func normalizedKeys(_ minimumSizes: [String: Int64]) -> [String: Int64] {
        guard !minimumSizes.isEmpty else { return minimumSizes }
        var normalized: [String: Int64] = [:]
        normalized.reserveCapacity(minimumSizes.count)
        for (key, value) in minimumSizes {
            let normalizedKey = Candidate.normalizedPathKey(for: URL(fileURLWithPath: key))
            if let existing = normalized[normalizedKey] {
                normalized[normalizedKey] = max(existing, value)
            } else {
                normalized[normalizedKey] = value
            }
        }
        return normalized
    }

    private static func makeResult(
        for entry: ResolvedCandidate,
        minimumSizes: [String: Int64],
        sizeOf: @Sendable (URL) -> SizeOutcome
    ) -> EntryOutcome {
        let candidate = entry.candidate
        switch sizeOf(candidate.path) {
        case .cancelled:
            return .skipped
        case .unmeasurable:
            // The candidate's own metadata could not be read, so there is no
            // walk and no interior path to name — its own key is the only
            // identity available, and it is the right one.
            return .unreadable(paths: [candidate.pathKey])
        case .measured(let measurement):
            return outcome(
                for: entry, measurement: measurement, minimumSizes: minimumSizes)
        }
    }

    /// What a completed measurement means for the tallies.
    ///
    /// The `partialRead` check is the load-bearing half. A `chmod 000`
    /// directory does not throw — its stat succeeds and its enumerator yields
    /// nothing, so it arrives here as a real measurement of zero bytes with a
    /// recorded denial named by path. Treating that as an exclusion is how a
    /// scan that could not read a whole category still reported itself exact.
    private static func outcome(
        for entry: ResolvedCandidate,
        measurement: SizeMeasurement,
        minimumSizes: [String: Int64]
    ) -> EntryOutcome {
        let candidate = entry.candidate

        func noRow() -> EntryOutcome {
            // No row, and we know the reading was not clean: that is a hole in
            // the total, not a filter the user asked for. Carries the
            // measurement's OWN refusals, each named by the directory that
            // refused us — not this candidate's key. Substituting the
            // candidate's key both under-counted (two sealed children of one
            // readable directory collapsed into one refusal) and mislabelled
            // (it named a directory that was read successfully as one that
            // could not be read).
            //
            // The fallback covers the two shapes that genuinely have no
            // interior path to name: an `unmeasurableKind` — a symlink, socket
            // or fifo, where nothing refused us at all but the read still reads
            // as partial — and `.unmeasurable` from `makeResult`, where the
            // candidate's own metadata could not be read. A candidate that is
            // itself sealed does NOT need it: the enumerator's errorHandler
            // fires on the root it cannot open, so such a candidate already
            // names itself in `unreadablePaths`.
            //
            // `partialRead` rather than `unreadablePaths` alone, deliberately:
            // an unmeasurable kind produced no row either, and dropping it here
            // would be a user-visible change.
            guard measurement.partialRead else { return .excluded }
            return .unreadable(
                paths: measurement.unreadablePaths.isEmpty
                    ? [candidate.pathKey] : measurement.unreadablePaths)
        }

        // Zero bytes is normally nothing to show. The exception is an item whose
        // content is all hard-linked from outside: it frees nothing, so its size
        // is honestly zero, but it is a real folder the user can see in Finder
        // and dropping it would remove the only place that could say why. It
        // keeps its row and carries the explanation. See
        // `SizeMeasurement.sharedBytesWithheld`.
        guard measurement.bytes > 0 || measurement.sharedBytesWithheld > 0 else {
            return noRow()
        }
        if let minimum = minimumSizes[candidate.pathKey], measurement.bytes < minimum {
            return noRow()
        }

        return .measured(
            ScanResult(
                path: candidate.path,
                category: candidate.category,
                tier: candidate.tier,
                removability: candidate.removability,
                sizeBytes: measurement.bytes,
                lastModified: SizeCalculator.lastModified(at: candidate.path),
                displayName: candidate.displayName,
                partialRead: measurement.partialRead,
                unreadablePaths: measurement.unreadablePaths,
                sharedBytesWithheld: measurement.sharedBytesWithheld,
                isDeletable: entry.isDeletable
            )
        )
    }

    /// What one candidate's measuring task produced. Distinguished at the
    /// task-group boundary, rather than inferred from a zero byte count, so
    /// that "never sized", "could not be read" and "measured, then deliberately
    /// filtered" cannot be conflated.
    private enum EntryOutcome: Sendable {
        case measured(ScanResult)
        /// Fully measured, then filtered out by the zero-byte check or a
        /// caller-supplied minimum-size threshold.
        case excluded
        /// Never sized: cancellation reached this entry before its task ran, or
        /// partway through its walk.
        case skipped
        /// Refused, not cancelled: either the candidate's own metadata could
        /// not be read, or its walk hit denied entries and produced no row.
        /// Carries every directory that refused us, named — a set rather than
        /// one path, because a single candidate can be refused several
        /// distinct directories and each is its own hole in the total. Falls
        /// back to the candidate's own key only where there is no interior
        /// path to name: an unmeasurable kind, or metadata that could not be
        /// read at all.
        case unreadable(paths: Set<String>)
    }
}
