import Testing
import Foundation
@testable import DDCCCore

private func candidate(
    _ url: URL,
    category: CleanCategory = .appCaches,
    tier: RemovalTier = .safe,
    removability: Removability = .removable,
    specificity: Specificity = .enumerated
) -> Candidate {
    Candidate(
        path: url, category: category, tier: tier, removability: removability,
        specificity: specificity, displayName: "\(category.rawValue): \(url.lastPathComponent)"
    )
}

private func context(root: URL, declared: Set<String> = []) -> PathGuard.Context {
    PathGuard.Context(scanRoot: root, declaredPaths: declared)
}

/// Pins `Candidate`'s own trailing-slash normalization directly, independent
/// of anything `CandidateResolver` does with it. This property has caused
/// trouble at multiple sites in this project (it is exactly why several
/// assertions in this file compare against `candidate(url).path` rather than
/// a fixture URL's raw `.standardizedFileURL`), so it gets one direct test.
@Test func candidatePathKeyIsSlashFreeRegardlessOfDirectoryHint() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let hinted = try tree.directory("Library/Caches/thing")
        let unhinted = URL(fileURLWithPath: hinted.path(percentEncoded: false))

        let fromHinted = candidate(hinted)
        let fromUnhinted = candidate(unhinted)

        #expect(fromHinted.pathKey.hasSuffix("/") == false)
        #expect(fromHinted.pathKey == fromUnhinted.pathKey)
    }
}

/// `Candidate.normalizedPathKey(for:)` is the single definition other call
/// sites (e.g. `Measurer`'s `minimumSizes` lookup) are meant to reuse instead
/// of hand-rolling their own trailing-slash strip. Pins that it can never
/// silently drift from `Candidate.pathKey` itself, across the three shapes
/// that have caused mismatches before: a directory-hinted URL, a plain
/// (non-hinted) URL, and a path that was already slash-free.
@Test func normalizedPathKeyAgreesWithCandidatePathKey() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let hinted = try tree.directory("Library/Caches/thing")
        let unhinted = URL(fileURLWithPath: hinted.path(percentEncoded: false))
        var alreadyBare = hinted.path(percentEncoded: false)
        if alreadyBare.hasSuffix("/") { alreadyBare.removeLast() }
        let bare = URL(fileURLWithPath: alreadyBare)

        let expected = candidate(hinted).pathKey

        #expect(Candidate.normalizedPathKey(for: hinted) == expected)
        #expect(Candidate.normalizedPathKey(for: unhinted) == expected)
        #expect(Candidate.normalizedPathKey(for: bare) == expected)
    }
}

@Test func refusedCandidatesAreDropped() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let shallow = try tree.directory("Documents")            // one level: refused
        let deep = try tree.directory("code/project/node_modules")  // two levels: allowed

        let resolved = CandidateResolver.resolve(
            [candidate(shallow), candidate(deep)], in: context(root: root))

        #expect(resolved.count == 1)
        // Compared via the same `candidate(...)` factory used to build the
        // inputs (which routes through `Candidate.init`'s normalization) so
        // this does not re-derive path-string handling that already exists:
        // a directory-hinted URL from `FixtureTree` keeps its trailing slash
        // through `.standardizedFileURL`, while `Candidate` strips it.
        #expect(resolved.first?.candidate.path == candidate(deep).path)
    }
}

@Test func lockedCandidatesSurviveButAreNotDeletable() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let locked = try tree.directory("SystemCaches")

        let resolved = CandidateResolver.resolve(
            [candidate(locked, removability: .requiresPrivileges)], in: context(root: root))

        #expect(resolved.count == 1)
        #expect(resolved.first?.verdict == .lockedInformational)
        #expect(resolved.first?.isDeletable == false)
    }
}

/// The double-counting bug: the same path arrives from an explicit pattern and
/// from an enumeration sweep, and was reported and totalled twice.
@Test func samePathFromTwoSourcesKeepsTheExplicitOne() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let shared = try tree.directory("Library/Caches/com.apple.Safari")

        let resolved = CandidateResolver.resolve([
            candidate(shared, category: .appCaches, specificity: .enumerated),
            candidate(shared, category: .browserData, specificity: .explicit),
        ], in: context(root: root))

        #expect(resolved.count == 1)
        #expect(resolved.first?.candidate.category == .browserData)
    }
}

@Test func samePathWithEqualSpecificityKeepsTheHigherTier() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let shared = try tree.directory("Library/Caches/thing")

        let resolved = CandidateResolver.resolve([
            candidate(shared, tier: .destructive, specificity: .explicit),
            candidate(shared, tier: .safe, specificity: .explicit),
        ], in: context(root: root))

        #expect(resolved.count == 1)
        // Higher tier wins: a safe classification must never be able to
        // downgrade a destructive one for the same path.
        #expect(resolved.first?.candidate.tier == .destructive)
    }
}

/// Winner selection is only guaranteed to enforce the tier ordering when
/// specificity is equal (see `samePathWithEqualSpecificityKeepsTheHigherTier`).
/// Across specificities, the explicit entry legitimately wins identity even
/// when it is the lower tier — but the resulting entry must still carry at
/// least the highest tier among everything collapsed into it, or a
/// `.destructive` enumerated candidate could be silently absorbed into a
/// `.safe` explicit one.
@Test func explicitWinnerTierIsClampedUpToTheHighestAbsorbedTier() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let shared = try tree.directory("Library/Caches/thing")

        let resolved = CandidateResolver.resolve([
            candidate(shared, tier: .safe, specificity: .explicit),
            candidate(shared, tier: .destructive, specificity: .enumerated),
        ], in: context(root: root))

        #expect(resolved.count == 1)
        // Wins identity/specificity as the explicit entry...
        #expect(resolved.first?.candidate.specificity == .explicit)
        // ...but cannot understate the risk of what it absorbed.
        #expect(resolved.first?.candidate.tier == .destructive)
    }
}

@Test func samePathDedupIsDeterministicAcrossInputOrder() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let shared = try tree.directory("Library/Caches/thing")
        let a = candidate(shared, category: .appCaches, specificity: .enumerated)
        let b = candidate(shared, category: .browserData, specificity: .explicit)

        let forward = CandidateResolver.resolve([a, b], in: context(root: root))
        let backward = CandidateResolver.resolve([b, a], in: context(root: root))

        #expect(forward.first?.candidate.category == backward.first?.candidate.category)
    }
}

/// The real profile table double-classifies these two directories: an
/// `appCaches` `.subdirs(of: "~/Library/Caches", tier: .safe)` sweep enumerates
/// them alongside every other cache, while `homebrew` and `macDevCaches` each
/// also declare them as explicit `.costly` paths. Rule 2 must resolve both to
/// the single, more cautious `.costly` entry — without this pinned, a future
/// change to the specificity comparison would silently make two global,
/// shared caches one-click deletable.
@Test func homebrewAndSwiftPMCachesResolveToTheExplicitCostlyEntry() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let homebrew = try tree.directory("Library/Caches/Homebrew")
        let swiftpm = try tree.directory("Library/Caches/org.swift.swiftpm")

        let resolved = CandidateResolver.resolve([
            candidate(homebrew, category: .appCaches, tier: .safe, specificity: .enumerated),
            candidate(homebrew, category: .homebrew, tier: .costly, specificity: .explicit),
            candidate(swiftpm, category: .appCaches, tier: .safe, specificity: .enumerated),
            candidate(swiftpm, category: .macDevCaches, tier: .costly, specificity: .explicit),
        ], in: context(root: root))

        #expect(resolved.count == 2)

        let homebrewEntry = resolved.first { $0.candidate.path == candidate(homebrew).path }
        let swiftpmEntry = resolved.first { $0.candidate.path == candidate(swiftpm).path }

        #expect(homebrewEntry?.candidate.category == .homebrew)
        #expect(homebrewEntry?.candidate.tier == .costly)
        #expect(swiftpmEntry?.candidate.category == .macDevCaches)
        #expect(swiftpmEntry?.candidate.tier == .costly)
    }
}

/// Containment: ~/.npm arrives from the walk, ~/.npm/_cacache from an explicit
/// path. Keeping the child means deleting strictly less.
@Test func ancestorIsDroppedInFavourOfDescendant() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let parent = try tree.directory("dev/.npm")
        let child = try tree.directory("dev/.npm/_cacache")

        let resolved = CandidateResolver.resolve(
            [candidate(parent), candidate(child)], in: context(root: root))

        #expect(resolved.count == 1)
        #expect(resolved.first?.candidate.path == candidate(child).path)
    }
}

@Test func ancestorWithSeveralDescendantsIsDroppedOnce() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let parent = try tree.directory("dev/cache")
        let first = try tree.directory("dev/cache/one")
        let second = try tree.directory("dev/cache/two")

        let resolved = CandidateResolver.resolve(
            [candidate(parent), candidate(first), candidate(second)], in: context(root: root))

        #expect(resolved.count == 2)
        #expect(Set(resolved.map(\.candidate.path.lastPathComponent)) == ["one", "two"])
    }
}

@Test func middleOfAThreeLevelChainIsAlsoDropped() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let top = try tree.directory("dev/a")
        let middle = try tree.directory("dev/a/b")
        let bottom = try tree.directory("dev/a/b/c")

        let resolved = CandidateResolver.resolve(
            [candidate(top), candidate(middle), candidate(bottom)], in: context(root: root))

        #expect(resolved.count == 1)
        #expect(resolved.first?.candidate.path == candidate(bottom).path)
    }
}

@Test func siblingsAreBothKept() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let one = try tree.directory("dev/projectA/node_modules")
        let two = try tree.directory("dev/projectB/node_modules")

        let resolved = CandidateResolver.resolve(
            [candidate(one), candidate(two)], in: context(root: root))
        #expect(resolved.count == 2)
    }
}

/// A path-prefix check without the separator would treat these as related.
@Test func prefixSimilarSiblingsAreNotTreatedAsNested() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let short = try tree.directory("dev/cache")
        let similar = try tree.directory("dev/cache-extra")

        let resolved = CandidateResolver.resolve(
            [candidate(short), candidate(similar)], in: context(root: root))
        #expect(resolved.count == 2)
    }
}

/// Regression: sorting on the bare `pathKey` puts `dev/cache-extra` between
/// `dev/cache` and `dev/cache/inner`, because `-` (0x2D) sorts below `/`
/// (0x2F). A one-element lookahead from `dev/cache` would then see the
/// unrelated sibling next, wrongly conclude `dev/cache` has no descendant,
/// and keep it alongside its own child. Sorting on `pathKey + "/"` must
/// collapse this to exactly the sibling and the descendant.
@Test func siblingSortingBeforeTheSeparatorDoesNotHideANestedDescendant() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let ancestor = try tree.directory("dev/cache")
        let sibling = try tree.directory("dev/cache-extra")
        let descendant = try tree.directory("dev/cache/inner")

        let resolved = CandidateResolver.resolve(
            [candidate(ancestor), candidate(sibling), candidate(descendant)],
            in: context(root: root))

        #expect(resolved.count == 2)
        #expect(Set(resolved.map(\.candidate.path.lastPathComponent)) == ["cache-extra", "inner"])
    }
}

/// Same defect, dotted variant: `.` (0x2E) also sorts below `/` (0x2F).
@Test func dottedSiblingDoesNotHideANestedDescendant() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let ancestor = try tree.directory("dev/cache")
        let sibling = try tree.directory("dev/cache.bak")
        let descendant = try tree.directory("dev/cache/inner")

        let resolved = CandidateResolver.resolve(
            [candidate(ancestor), candidate(sibling), candidate(descendant)],
            in: context(root: root))

        #expect(resolved.count == 2)
        #expect(Set(resolved.map(\.candidate.path.lastPathComponent)) == ["cache.bak", "inner"])
    }
}

/// Same defect at the extreme: a space is 0x20, further below `/` than
/// either `-` or `.`, so it is the most likely character to slip past a
/// bare-path sort undetected.
@Test func spaceContainingSiblingDoesNotHideANestedDescendant() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let ancestor = try tree.directory("dev/cache")
        let sibling = try tree.directory("dev/cache backup")
        let descendant = try tree.directory("dev/cache/inner")

        let resolved = CandidateResolver.resolve(
            [candidate(ancestor), candidate(sibling), candidate(descendant)],
            in: context(root: root))

        #expect(resolved.count == 2)
        #expect(Set(resolved.map(\.candidate.path.lastPathComponent)) == ["cache backup", "inner"])
    }
}

/// Same defect, deeper: a prefix-similar sibling interposed one level up a
/// three-level chain must not stop the middle entry from still being
/// recognised as, and dropped as, an ancestor of the bottom entry.
@Test func prefixSimilarSiblingDoesNotHideADeeperChain() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let top = try tree.directory("dev/a")
        let sibling = try tree.directory("dev/a-x")
        let middle = try tree.directory("dev/a/b")
        let bottom = try tree.directory("dev/a/b/c")

        let resolved = CandidateResolver.resolve(
            [candidate(top), candidate(sibling), candidate(middle), candidate(bottom)],
            in: context(root: root))

        #expect(resolved.count == 2)
        #expect(Set(resolved.map(\.candidate.path.lastPathComponent)) == ["a-x", "c"])
    }
}

@Test func lockedAncestorIsStillDroppedForADeletableDescendant() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let parent = try tree.directory("dev/locked")
        let child = try tree.directory("dev/locked/inner")

        let resolved = CandidateResolver.resolve([
            candidate(parent, removability: .requiresPrivileges),
            candidate(child),
        ], in: context(root: root))

        #expect(resolved.count == 1)
        #expect(resolved.first?.candidate.path == candidate(child).path)
    }
}

/// Pins `resolve`'s documented stage order — guard, then same-path dedup,
/// then containment collapse — directly, not just the two collapse
/// behaviours in isolation. Every other test in this file collapses cleanly
/// under either order: a same-path duplicate alone dedups fine standalone,
/// and a distinct ancestor/descendant pair collapses fine standalone. The
/// two collisions only interact under a wrong order: with dedup run AFTER
/// containment, `collapseContainment` sees two raw, still-undeduplicated
/// copies of the ancestor plus the descendant. Sorted by `pathKey + "/"`,
/// each ancestor copy's immediate neighbour is checked for the
/// ancestor-prefix relationship — the first ancestor copy's neighbour is the
/// *second* ancestor copy, which has the identical (not descendant) pathKey
/// and so fails the prefix-with-separator check, so the first copy survives
/// containment uncollapsed; only the second ancestor copy (whose neighbour
/// is genuinely the descendant) gets dropped. Same-path dedup then runs on
/// the survivors — one ancestor copy plus the descendant — and finds no
/// remaining collision to collapse, so both survive: a duplicated ancestor
/// has slipped through containment collapse entirely, double-counting bytes
/// and letting a lower-tier ancestor enclose a higher-tier descendant.
/// Verified by mutation: swapping the `collapseSamePath` and
/// `collapseContainment` calls in `resolve` makes this fail with
/// `resolved.count == 2`; restoring the order makes it pass again.
@Test func stageOrderDedupBeforeContainmentPreventsADuplicatedAncestorSurviving() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let parent = try tree.directory("T/a/b")
        let child = try tree.directory("T/a/b/c")

        let resolved = CandidateResolver.resolve(
            [candidate(parent), candidate(parent), candidate(child)],
            in: context(root: root))

        #expect(resolved.count == 1)
        #expect(resolved.first?.candidate.path == candidate(child).path)
    }
}

@Test func emptyInputYieldsEmptyOutput() throws {
    try withTempDirectory { root in
        #expect(CandidateResolver.resolve([], in: context(root: root)).isEmpty)
    }
}

@Test func resolvedOutputIsSortedByPathForStableDisplay() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let b = try tree.directory("dev/b/node_modules")
        let a = try tree.directory("dev/a/node_modules")

        let resolved = CandidateResolver.resolve(
            [candidate(b), candidate(a)], in: context(root: root))
        let paths = resolved.map(\.candidate.pathKey)
        #expect(paths == paths.sorted())
    }
}
