// Sources/DDCCCore/Scanner/CandidateResolver.swift
import Foundation

/// Turns raw discovery output into the set of paths that will actually be
/// measured and offered.
///
/// This stage exists because the deduplication policy needs a global view.
/// Phase-by-phase discovery emits `~/.npm/_cacache` long before the walk finds
/// that `~/.npm` contains it, so deciding which survives is impossible while
/// results are still streaming.
public enum CandidateResolver {

    /// Order matters: guard, then same-path dedup, then containment collapse.
    public static func resolve(
        _ candidates: [Candidate],
        in context: PathGuard.Context
    ) -> [ResolvedCandidate] {
        let permitted = applyGuard(candidates, in: context)
        let deduplicated = collapseSamePath(permitted)
        return collapseContainment(deduplicated)
            .sorted { $0.candidate.pathKey < $1.candidate.pathKey }
    }

    // MARK: - 1. Guard

    private static func applyGuard(
        _ candidates: [Candidate],
        in context: PathGuard.Context
    ) -> [ResolvedCandidate] {
        candidates.compactMap { candidate in
            let verdict = PathGuard.evaluate(
                candidate.path, removability: candidate.removability, in: context)
            switch verdict {
            case .allowed, .lockedInformational:
                return ResolvedCandidate(candidate: candidate, verdict: verdict)
            case .refused:
                return nil
            }
        }
    }

    // MARK: - 2. Same path

    /// Keeps one entry per path. An explicit pattern beats an enumeration
    /// sweep, and ties within equal specificity break to the HIGHER (more
    /// restrictive) tier, then to the earlier-declared category, so output
    /// does not depend on discovery order.
    ///
    /// Winner selection alone only guarantees the tier ordering when
    /// specificity is equal: an `.explicit` `.safe` candidate can win
    /// identity over an `.enumerated` `.destructive` one. So the resulting
    /// tier must never be able to understate risk: after a winner is chosen
    /// for each path, its tier is clamped up to the maximum tier seen among
    /// every candidate collapsed into it. The winner keeps its own identity,
    /// category, specificity and display name; only the tier can be raised.
    private static func collapseSamePath(
        _ resolved: [ResolvedCandidate]
    ) -> [ResolvedCandidate] {
        var best: [String: ResolvedCandidate] = [:]
        var worstTier: [String: RemovalTier] = [:]

        for entry in resolved {
            let key = entry.candidate.pathKey
            worstTier[key] = max(worstTier[key] ?? entry.candidate.tier, entry.candidate.tier)

            guard let incumbent = best[key] else {
                best[key] = entry
                continue
            }
            if prefers(entry, over: incumbent) {
                best[key] = entry
            }
        }

        return best.map { key, winner in
            clampTier(of: winner, upTo: worstTier[key] ?? winner.candidate.tier)
        }
    }

    /// Raises `winner`'s tier to `floor` when a lower-tier entry won on
    /// identity but a higher-tier entry for the same path was absorbed. A
    /// no-op tier reconstruction is skipped so the common case (no
    /// same-path collision to clamp against) allocates nothing extra.
    private static func clampTier(
        of winner: ResolvedCandidate, upTo floor: RemovalTier
    ) -> ResolvedCandidate {
        guard winner.candidate.tier != floor else { return winner }

        let clamped = Candidate(
            path: winner.candidate.path,
            category: winner.candidate.category,
            tier: floor,
            removability: winner.candidate.removability,
            specificity: winner.candidate.specificity,
            displayName: winner.candidate.displayName
        )
        return ResolvedCandidate(candidate: clamped, verdict: winner.verdict)
    }

    private static func prefers(
        _ challenger: ResolvedCandidate,
        over incumbent: ResolvedCandidate
    ) -> Bool {
        let a = challenger.candidate
        let b = incumbent.candidate

        if a.specificity != b.specificity {
            return a.specificity == .explicit
        }
        if a.tier != b.tier {
            // Higher tier wins — preferring the lower tier would silently
            // downgrade a destructive path to a safe one.
            return a.tier > b.tier
        }
        return categoryRank(a.category) < categoryRank(b.category)
    }

    private static func categoryRank(_ category: CleanCategory) -> Int {
        CleanCategory.allCases.firstIndex(of: category) ?? Int.max
    }

    // MARK: - 3. Containment

    /// Drops any candidate that strictly contains another candidate.
    ///
    /// Sorted on `pathKey + "/"`, not the bare `pathKey`: a bare-path sort
    /// can put a sibling between an ancestor and its own descendant (e.g.
    /// `dev/cache`, `dev/cache-extra`, `dev/cache/inner`, since `-` sorts
    /// below `/`), which breaks the one-element lookahead below. The
    /// appended separator forces every descendant to sort immediately after
    /// its ancestor. Do not simplify this back to a bare `pathKey` sort —
    private static func collapseContainment(
        _ resolved: [ResolvedCandidate]
    ) -> [ResolvedCandidate] {
        guard resolved.count > 1 else { return resolved }

        let sorted = resolved.sorted {
            $0.candidate.pathKey + "/" < $1.candidate.pathKey + "/"
        }
        var kept: [ResolvedCandidate] = []
        kept.reserveCapacity(sorted.count)

        for (index, entry) in sorted.enumerated() {
            let nextIndex = index + 1
            guard nextIndex < sorted.count else {
                kept.append(entry)
                continue
            }
            // `pathKey` is always separator-free (`Candidate.normalized`
            // strips any trailing slash), so appending exactly one "/" here
            // always yields the correct ancestor-directory prefix.
            let prefix = entry.candidate.pathKey + "/"
            let isAncestor = sorted[nextIndex].candidate.pathKey.hasPrefix(prefix)
            if isAncestor == false {
                kept.append(entry)
            }
        }

        return kept
    }
}
