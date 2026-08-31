import Testing
import Foundation
@testable import DDCCCore

/// A tally cannot be deduplicated; a path can. These pin `RefusalSet`'s own
/// arithmetic directly, before the engine-level tests below exercise it
/// through real refusals.
@Test func unionOfTwoRefusalSetsSharingAPathDedupesToOne() {
    let a = RefusalSet(paths: ["/Users/x/.cargo/registry"])
    let b = RefusalSet(paths: ["/Users/x/.cargo/registry"])
    #expect(a.union(b).paths.count == 1)
    #expect(a.union(b).count == 1)
}

/// A set sharing no paths simply combines; this pins that `union` does not
/// accidentally drop or double either side's identified refusals.
@Test func unionOfDisjointPathsKeepsBoth() {
    let a = RefusalSet(paths: ["/a"])
    let b = RefusalSet(paths: ["/b"])
    let combined = a.union(b)
    #expect(combined.paths == ["/a", "/b"])
    #expect(combined.count == 2)
}

/// An ancestor absorbs a direct child: the child's bytes are already missing
/// via the ancestor, so counting both overstates the hole.
@Test func unionOfAncestorAndDirectChildCollapsesToOne() {
    let a = RefusalSet(paths: ["/a"])
    let b = RefusalSet(paths: ["/a/b"])
    #expect(a.union(b).paths == ["/a"])
    #expect(a.union(b).count == 1)
}

/// Absorption is not depth-one: a grandchild is still absorbed by an
/// ancestor two levels up.
@Test func unionOfAncestorAndGrandchildCollapsesToOne() {
    let a = RefusalSet(paths: ["/a"])
    let b = RefusalSet(paths: ["/a/b/c"])
    #expect(a.union(b).paths == ["/a"])
    #expect(a.union(b).count == 1)
}

/// Siblings never absorb each other — `/a/b` and `/a/c` are independent
/// holes, neither an ancestor of the other.
@Test func unionOfSiblingsStaysTwo() {
    let a = RefusalSet(paths: ["/a/b"])
    let b = RefusalSet(paths: ["/a/c"])
    let combined = a.union(b)
    #expect(combined.paths == ["/a/b", "/a/c"])
    #expect(combined.count == 2)
}

/// The component-boundary case: `/a/bc` is not inside `/a/b`. A bare
/// `hasPrefix` collapses these to one and this test is what catches it —
/// the identical error `PathDisplay.tildeAbbreviated` is written to avoid.
@Test func siblingWithExtendedNameIsNotAbsorbed() {
    let a = RefusalSet(paths: ["/a/bc"])
    let b = RefusalSet(paths: ["/a/b"])
    let combined = a.union(b)
    #expect(combined.paths == ["/a/bc", "/a/b"])
    #expect(combined.count == 2)
}

/// The invariant lives in the initialiser, not only in `union`: a set built
/// directly with nested paths already reports the collapsed count.
@Test func aSetConstructedDirectlyWithNestedPathsAlreadyCollapses() {
    let set = RefusalSet(paths: ["/a", "/a/b", "/a/b/c"])
    #expect(set.paths == ["/a"])
    #expect(set.count == 1)
}

/// The doc comment on `init` names trailing-slash normalization as a
/// behavior, not an implementation detail, so the shape it produces is
/// pinned directly: a trailing slash is gone from `paths` even when there is
/// no sibling or ancestor around to expose it via collapsing.
@Test func initNormalizesATrailingSlashOffAPath() {
    let set = RefusalSet(paths: ["/a/b/"])
    #expect(set.paths == ["/a/b"])
}

/// Two engines can spell the same refusal differently — one with a trailing
/// slash, one without — and that must not render as two folders. Mutation
/// testing showed this survives `normalizingTrailingSlash` being removed
/// from `init` entirely: `collapsingDescendants` absorbs `/a/b/` as a
/// "descendant" of `/a/b` on its own, since `path.hasPrefix(ancestor + "/")`
/// reduces to `(/a/b/).hasPrefix(/a/b/)`, trivially true. Normalization
/// itself is pinned elsewhere — `initNormalizesATrailingSlashOffAPath` and
/// `trailingSlashOnTheAncestorDoesNotDefeatDescendantAbsorption` are the
/// tests that actually fail when it goes.
@Test func twoSpellingsOfOnePathWithAndWithoutTrailingSlashDedupeToOne() {
    let set = RefusalSet(paths: ["/a/b", "/a/b/"])
    #expect(set.count == 1)
}

/// Normalization runs before collapsing, not after: an unnormalized `/a/`
/// would form the boundary string `/a/` + `/` = `/a//`, which `/a/b` does
/// not start with, so the `ancestor + "/"` check fails and nothing is
/// absorbed. This is the interaction most likely to break silently if the
/// ordering in `init` were ever reversed.
@Test func trailingSlashOnTheAncestorDoesNotDefeatDescendantAbsorption() {
    let set = RefusalSet(paths: ["/a/", "/a/b"])
    #expect(set.count == 1)
}

/// `.none` is the identity element `union` needs when folding refusals from
/// an arbitrary number of engines, some of which may contribute nothing.
/// `x` carries a path so the identity is checked against a non-empty set.
@Test func unionWithNoneIsIdentityInBothDirections() {
    #expect(RefusalSet.none.count == 0)
    let x = RefusalSet(paths: ["/a"])
    #expect(x.union(.none) == x)
    #expect(RefusalSet.none.union(x) == x)
}

/// The union property, exercised end to end with two real engines: `Measurer`
/// (which identifies a refusal it produced no row for by the candidate's own
/// path) and `FileScanner.walk` (whose `errorHandler` records the URL it is
/// handed). It is checked on the two report types that carry refusals —
/// `MeasureOutcome.refusals` and `WalkReport.refusals` — rather than on
/// `ScanCoordinator`, which unions them: a failure here names the engine that
/// leaked, where a failure there would only say the count was wrong.
///
/// A non-`Library` fixture, by design: the walk's `skipDirectories` is exactly
/// what makes `~/Library/...` patterns immune to this collision, so a Library
/// fixture would pass with or without the union and prove nothing.
@Test func aDirectoryRefusedByBothMeasuringAndTheWalkContributesOnceWhenUnioned() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let registry = try tree.directory("cargo/registry")
        try tree.file("cargo/registry/inner.bin", byteCount: 16)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: registry.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: registry.path(percentEncoded: false))
        }

        // `registry` itself is chmod'd, not an ancestor of it: `probeDirectory`
        // (a plain stat) succeeds regardless of a target's own permission bits
        // — only an unreadable ANCESTOR fails a stat. So discovery would treat
        // this as a normal candidate; it is `Measurer`, sizing that candidate
        // and finding its own enumerator refused, that identifies the refusal.
        // `.dir("node_modules", ...)` exists only so `walk`'s pattern lookup is
        // non-empty and it actually traverses the tree instead of returning
        // immediately.
        let profile = ScanProfile(category: .packageCaches, patterns: [
            .path("~/cargo/registry", tier: .safe),
            .dir("node_modules", tier: .safe),
        ])

        let candidate = Candidate(
            path: registry, category: profile.category, tier: .safe,
            removability: .removable, specificity: .explicit,
            displayName: "cargo: registry"
        )
        let resolvedCandidate = ResolvedCandidate(candidate: candidate, verdict: .allowed)

        let measured = await Measurer.measure(
            [resolvedCandidate], minimumSizes: [:], onProgress: { _ in })
        let walkResult = await FileScanner().walk(
            root: root, profiles: [profile], onProgress: { _ in })

        // Both engines independently refuse the exact same physical directory.
        #expect(measured.refusals.count == 1)
        #expect(walkResult.refusals.count == 1)

        // Property: a directory refused by both contributes ONE, not two.
        #expect(measured.refusals.union(walkResult.refusals).count == 1)
    }
}

/// The shape the existing dedup test does NOT cover, and the reason
/// `unreadableDirectories` was a floor rather than a count.
///
/// The test above exercises a candidate refused outright, which already
/// produced a named path. This one exercises a candidate that was sized
/// *successfully* and hit a denial somewhere inside it. That denial has to
/// carry a path: a bare tally cannot be reconciled with the walk's own refusal
/// of the same physical directory by name, so one hole in the disk would
/// render as two.
///
/// Before this change: `anonymous: 1` plus `paths: {sealed}` = 2. After: 1.
/// Verified against the pre-change code before this test was written.
@Test func aDenialInsideASizedDirectoryDedupesAgainstTheWalksRefusalOfIt() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        // `parent` is readable and really is sized; `sealed` inside it is what
        // refuses the sizing walk. `walk` reaches `sealed` by its own route and
        // is refused by name.
        let parent = try tree.directory("cargo/registry")
        try tree.file("cargo/registry/readable.bin", byteCount: 16_384)
        let sealed = try tree.directory("cargo/registry/sealed")
        try tree.file("cargo/registry/sealed/inner.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sealed.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path(percentEncoded: false))
        }

        // `.dir("node_modules", ...)` names a directory that does NOT exist in
        // this fixture, and that is deliberate — it exists only so `walk`'s
        // pattern lookup is non-empty and it actually traverses instead of
        // returning immediately. Naming `sealed` here would be worse than
        // useless: a matched directory gets `enumerator.skipDescendants()`, so
        // the walk would never attempt the descent that produces the refusal,
        // and the test would pin nothing.
        //
        // A non-Library fixture, because the walk's `skipDirectories` is
        // exactly what makes `~/Library/...` immune to this collision — a
        // Library fixture would pass either way and prove nothing.
        //
        // `.path("~/cargo/registry", ...)` is inert below: `walk` only reads
        // `.directoryName` patterns, and the measured half's `candidate` is
        // constructed by hand, not derived from this profile via
        // `discoverPathPatterns`. It is kept for readability — it documents
        // what a real profile targeting this fixture would declare — not
        // because it drives anything here.
        let profile = ScanProfile(category: .packageCaches, patterns: [
            .path("~/cargo/registry", tier: .safe),
            .dir("node_modules", tier: .safe),
        ])

        let candidate = Candidate(
            path: parent, category: profile.category, tier: .safe,
            removability: .removable, specificity: .explicit,
            displayName: "cargo: registry"
        )
        let measured = await Measurer.measure(
            [ResolvedCandidate(candidate: candidate, verdict: .allowed)],
            minimumSizes: [:], onProgress: { _ in })
        let walkResult = await FileScanner().walk(
            root: root, profiles: [profile], onProgress: { _ in })

        // The candidate really was sized — this is not the refused-outright
        // shape the test above already covers.
        #expect(measured.results.count == 1)
        #expect((measured.results.first?.sizeBytes ?? 0) > 0)

        // Each engine sees the one hole once.
        #expect(measured.refusals.count == 1)
        #expect(walkResult.refusals.count == 1)

        // The property: one sealed directory, one refusal.
        #expect(measured.refusals.union(walkResult.refusals).count == 1)
    }
}

/// Deduplication survives only because both engines key their refusals through
/// `Candidate.normalizedPathKey`. The raw URLs do not agree: measured, the
/// enumerator reports a refused descendant as `/private/var/…` while the walk
/// reports `/var/…`, and it is `standardizedFileURL`'s `/private` rule inside
/// `normalizedPathKey` that reconciles them.
///
/// Pinned as its own assertion rather than left implicit in the test above,
/// because the failure mode is silent: store the raw path and the test above
/// fails for a reason nobody would connect to symlinks. This is the test that
/// stands between a future "simplification" and the return of this bug.
@Test func aRefusalFoundWhileSizingIsSpelledTheWayTheWalkSpellsIt() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let parent = try tree.directory("cache")
        try tree.file("cache/readable.bin", byteCount: 16_384)
        let sealed = try tree.directory("cache/sealed")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sealed.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path(percentEncoded: false))
        }

        let candidate = Candidate(
            path: parent, category: .packageCaches, tier: .safe,
            removability: .removable, specificity: .explicit, displayName: "cache")
        let measured = await Measurer.measure(
            [ResolvedCandidate(candidate: candidate, verdict: .allowed)],
            minimumSizes: [:], onProgress: { _ in })

        #expect(measured.refusals.paths == [Candidate.normalizedPathKey(for: sealed)])
        #expect(measured.refusals.paths.allSatisfy { !$0.hasPrefix("/private/") })
    }
}

// MARK: - Collapsing: correctness under randomisation, and cost

/// The definition `collapsingDescendants` must satisfy, written the slow,
/// obvious way: drop a path when some *other* path in the set is a
/// component-boundary ancestor of it. The implementation is an optimisation of
/// exactly this, so the two must agree on every input.
private func bruteForceCollapse(_ paths: Set<String>) -> Set<String> {
    paths.filter { path in
        !paths.contains { ancestor in
            ancestor != path && path.hasPrefix(ancestor + "/")
        }
    }
}

/// A deterministic generator, so a failure names an input that reproduces
/// rather than one that vanishes on the next run.
private struct Xorshift {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}

/// The test that earns its place: an ancestor and its descendant are not
/// necessarily adjacent once sorted, because `-` (0x2D) sorts before `/`
/// (0x2F). A collapse that only compares each path with the previously kept
/// one therefore keeps `/a/c` alive even though `/a` is present — it saw
/// `/a-b` in between and forgot `/a`. That implementation passes every
/// hand-written nesting fixture above and is still wrong, which is why the
/// randomised comparison below exists rather than more fixtures.
@Test func aPathSortingBetweenAnAncestorAndItsDescendantIsStillAbsorbed() {
    let set = RefusalSet(paths: ["/a", "/a-b", "/a/c"])
    #expect(set.paths == ["/a", "/a-b"])
    #expect(!set.paths.contains("/a/c"))
}

@Test func collapsingAgreesWithItsBruteForceDefinitionOnRandomisedSets() {
    // Components chosen so that boundary cases occur often: `a` vs `a-b` vs
    // `ab` produce the prefix-but-not-child shape, and repeats produce real
    // ancestor/descendant pairs.
    let components = ["a", "b", "a-b", "ab", "b-c", "x"]
    var rng = Xorshift(seed: 0x9E37_79B9_7F4A_7C15)

    for iteration in 0..<2_000 {
        var input = Set<String>()
        for _ in 0..<(2 + rng.next(5)) {
            var path = ""
            for _ in 0..<(1 + rng.next(3)) { path += "/" + components[rng.next(components.count)] }
            input.insert(path)
        }

        let actual = RefusalSet(paths: input).paths
        let expected = bruteForceCollapse(input)
        #expect(actual == expected, "iteration \(iteration), input \(input.sorted())")
    }
}

/// Collapsing must not compare every path against every other: the cost would
/// grow with the square of the refusal count while `union` re-collapses the
/// whole set on every single refusal, and a tree with thousands of sealed
/// directories then freezes the app for minutes. Measured pairwise: 20,000
/// paths took ~31s in one collapse, and accumulating 2,000 refusals one union
/// at a time took ~3.3 minutes.
///
/// The time limit is deliberately far above the fixed cost (tens of
/// milliseconds) and far below the old one, so this fails on the algorithm
/// rather than on a slow machine.
@Test(.timeLimit(.minutes(1)))
func collapsingALargeRefusalSetDoesNotGrowWithTheSquareOfItsSize() {
    let paths = Set((0..<50_000).map { "/Users/x/Library/Caches/app/entry-\($0)/data" })
    let set = RefusalSet(paths: paths)
    // Siblings: none absorbs another, so every one survives.
    #expect(set.paths.count == 50_000)
}

/// The same accumulation cost, one layer up, in the engine that actually
/// produces most refusals. `walk`'s enumerator calls its `errorHandler` once
/// per directory it cannot descend into, and folding each refusal in with a
/// `union` re-collapses everything gathered so far.
///
/// This is the shape a first-run user hits: without Full Disk Access a walk is
/// refused a great many directories at once, which is precisely when a
/// code was slowest.
@Test(.timeLimit(.minutes(1)))
func aWalkRefusedManyDirectoriesDoesNotCostTheSquareOfTheirCount() async throws {
    try await withTempDirectory { root in
        let sealedCount = 20_000
        // Directly under the walked root, and named so they match no pattern:
        // the walk must actually try to descend into each one for its
        // enumerator to be refused. A sealed directory *inside* a matched
        // `node_modules` would be skipped along with the rest of its subtree
        // and refuse nothing.
        var sealed: [String] = []
        for index in 0..<sealedCount {
            let child = root.appending(path: "sealed-\(index)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            sealed.append(child.path(percentEncoded: false))
        }
        for path in sealed {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        }
        defer {
            for path in sealed {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }

        let profile = ScanProfile(category: .packageCaches, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let report = await FileScanner().walk(
            root: root, profiles: [profile], onProgress: { _ in })

        // Siblings under one parent, so none absorbs another.
        #expect(report.refusals.count == sealedCount)
    }
}
