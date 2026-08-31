import Foundation

/// A path discovery has flagged, before it has been measured.
///
/// Discovery deliberately does not size candidates: resolution discards
/// overlaps, and recursive sizing is the expensive stage, so it runs only on
/// survivors.
public struct Candidate: Sendable, Equatable {
    public let path: URL
    public let category: CleanCategory
    public let tier: RemovalTier
    public let removability: Removability
    public let specificity: Specificity
    public let displayName: String

    public init(
        path: URL,
        category: CleanCategory,
        tier: RemovalTier,
        removability: Removability,
        specificity: Specificity,
        displayName: String
    ) {
        self.path = Candidate.normalized(path)
        self.category = category
        self.tier = tier
        self.removability = removability
        self.specificity = specificity
        self.displayName = displayName
    }

    /// Standardized absolute path, used as the deduplication key.
    public var pathKey: String { path.path(percentEncoded: false) }

    /// The standardized, slash-free path string for `url`.
    ///
    /// `URL.path(percentEncoded:)` preserves a trailing "/" for
    /// directory-hinted URLs (e.g. from `appending(path:directoryHint:)`);
    /// the legacy `.path` property strips it. Left to each call site, that
    /// ambiguity let the same bug recur independently in `Candidate`,
    /// `Measurer`, and `PathGuard` — two differently-derived strings for one
    /// path compare unequal, and a set or dictionary lookup keyed on one
    /// silently misses the other. This is the single place that decides
    /// what a path looks like as a comparison key; any call site needing
    /// the same guarantee (e.g. `Measurer`'s `minimumSizes` lookup) should
    /// call this rather than hand-roll another copy of the strip.
    public static func normalizedPathKey(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        var pathString = standardized.path(percentEncoded: false)
        if pathString.count > 1, pathString.hasSuffix("/") {
            pathString.removeLast()
        }
        return pathString
    }

    /// Standardized with any trailing directory slash removed, so a
    /// directory-hinted URL (e.g. from `appending(path:directoryHint:)`) and
    /// a plain enumerated one compare equal as dedup keys.
    private static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: Candidate.normalizedPathKey(for: url), isDirectory: false)
    }
}

/// A candidate that survived guard validation and deduplication.
public struct ResolvedCandidate: Sendable, Equatable {
    public let candidate: Candidate
    public let verdict: PathGuard.Verdict

    public init(candidate: Candidate, verdict: PathGuard.Verdict) {
        self.candidate = candidate
        self.verdict = verdict
    }

    /// False for locked informational rows.
    public var isDeletable: Bool { verdict.isAllowed }
}
