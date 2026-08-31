import Foundation

/// Refusals that reached a report, carrying identity wherever identity exists.
///
/// Two engines traverse overlapping territory, so a plain count cannot be
/// added up: discovery and the walk both reach `~/.cargo/registry`, and one
/// refused directory would render as two. Paths can be unioned. Tallies
/// cannot, which is the whole reason this is not an `Int`.
///
/// Two engines can also name the *same* seal with two different strings: seal
/// `Vault` and declare `Vault/Secret` as a profile path, and discovery reports
/// the leaf while the walk — whose enumerator fails on the ancestor it cannot
/// list, not the leaf it never reaches — reports `Vault`. Both strings are
/// individually true, but a descendant's missing bytes are already missing
/// via its ancestor, so `paths` absorbs any refusal that is a descendant of
/// another refusal in the same set, to any depth. Siblings never absorb each
/// other: `/a/b` and `/a/c` are independent holes, and the comparison is
/// anchored at a path-component boundary so `/a/bc` is not mistaken for
/// living inside `/a/b`.
///
/// Every refusal carries a path, including the denials `SizeCalculator` meets
/// *inside* a directory it can otherwise size. Both engines key through
/// `Candidate.normalizedPathKey`, which is what makes their spellings of one
/// directory compare equal.
public struct RefusalSet: Sendable, Equatable {
    /// Refusals of a specific directory, deduplicated across engines and
    /// collapsed so a sealed ancestor absorbs any of its own descendants.
    public let paths: Set<String>

    /// Normalises trailing slashes, then drops any path that has another
    /// path in `paths` as a proper ancestor. Enforced here rather than only
    /// in `union`, so a `RefusalSet` built directly by a single engine holds
    /// the same invariant as one produced by unioning two — otherwise
    /// `paths.count` means something different depending on how the set was
    /// constructed.
    public init(paths: Set<String>) {
        let normalized = Set(paths.map(Self.normalizingTrailingSlash))
        self.paths = Self.collapsingDescendants(of: normalized)
    }

    public var count: Int { paths.count }
    public static let none = RefusalSet(paths: [])

    public func union(_ other: RefusalSet) -> RefusalSet {
        RefusalSet(paths: paths.union(other.paths))
    }

    private static func normalizingTrailingSlash(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    /// Drops every path that lives inside another path of the same set.
    /// Matched at a path-component boundary (`other + "/"`), never by raw
    /// `hasPrefix`: `/a/bc` is not inside `/a/b`, and a bare prefix match
    /// says it is — the identical error `PathDisplay.tildeAbbreviated` was
    /// written to avoid.
    ///
    /// Asks each path whether the set holds one of *its own* ancestors, rather
    /// than comparing every path against every other. The work then grows with
    /// how deep a path is rather than with how many refusals there are, which
    /// is what makes a heavily refused scan survivable: comparing pairwise
    /// cost ~31s for 20,000 paths, and `union` re-collapses on every refusal,
    /// so accumulating a few thousand froze the app for minutes.
    ///
    /// Walking ancestors is also what keeps this correct. Sorting the paths
    /// and comparing each against the previously kept one looks equivalent and
    /// is not: `-` sorts before `/`, so `/a-b` lands between `/a` and `/a/c`,
    /// and `/a/c` survives an ancestor it should have been absorbed by.
    private static func collapsingDescendants(of paths: Set<String>) -> Set<String> {
        paths.filter { path in
            var ancestor = path
            while let slash = ancestor.lastIndex(of: "/") {
                ancestor = String(ancestor[ancestor.startIndex..<slash])
                if paths.contains(ancestor) { return false }
                // The last ancestor of an absolute path is the empty string,
                // whose boundary form is "/" — checked above before stopping,
                // so this agrees with the pairwise form even on that edge.
                if ancestor.isEmpty { break }
            }
            return true
        }
    }
}
