import Foundation
import Testing

@testable import DDCCCore

/// Which installed toolchain versions may be offered.
///
/// Every fixture here is the shape of this development machine, measured
/// nine node versions, `~/.nvm/alias/default` containing the
/// literal `node`, a real `lts/*` → `lts/krypton` chain, and twenty processes
/// live out of `v24.13.0`.
@Suite struct ToolchainVersionsTests {

    private let installed = [
        "v18.16.0", "v18.20.3", "v20.11.0", "v20.12.2", "v20.13.1",
        "v21.6.0", "v22.12.0", "v22.22.2", "v24.13.0",
    ].map { URL(fileURLWithPath: "/Users/x/.nvm/versions/node/\($0)", isDirectory: true) }

    private func stale(
        pointer: String? = nil,
        aliases: [String: String] = [:],
        running: [String] = []
    ) -> [String] {
        ToolchainVersions.stale(
            among: installed, pointer: pointer, resolveAlias: { aliases[$0] },
            runningExecutables: running.map { URL(fileURLWithPath: $0) }
        ).map(\.lastPathComponent)
    }

    /// Lexicographic ordering puts v20.9.0 above v20.13.1. That is not a
    /// cosmetic bug here: it would retain a version nobody uses and offer the
    /// one that is actually current.
    @Test func versionsAreOrderedNumericallyNotLexicographically() {
        #expect(ToolchainVersions.highest(of: ["v20.9.0", "v20.13.1"]) == "v20.13.1")
        #expect(ToolchainVersions.highest(of: ["v9.0.0", "v10.0.0"]) == "v10.0.0")
    }

    @Test func theNewestVersionIsNeverOffered() {
        #expect(stale().contains("v24.13.0") == false)
        #expect(stale().count == installed.count - 1)
    }

    /// nvm's `default` on this machine is the literal string `node`, meaning
    /// "the latest installed" rather than any file on disk.
    @Test func theNodeAliasMeansTheLatestInstalled() {
        #expect(ToolchainVersions.resolve("node", in: installed.map(\.lastPathComponent),
            resolveAlias: { _ in nil }) == "v24.13.0")
    }

    /// A pointer at something other than the newest retains that too, so two
    /// versions survive rather than one.
    @Test func theVersionThePointerNamesIsRetainedEvenWhenItIsNotTheNewest() {
        let offered = stale(pointer: "v20.13.1")
        #expect(offered.contains("v20.13.1") == false)
        #expect(offered.contains("v24.13.0") == false)
        #expect(offered.contains("v20.12.2"))
    }

    /// The real chain on this machine: default → lts/* → lts/krypton → version.
    @Test func anAliasChainIsFollowedToTheVersionItEndsAt() {
        let offered = stale(
            pointer: "lts/*", aliases: ["lts/*": "lts/krypton", "lts/krypton": "v22.22.2"])
        #expect(offered.contains("v22.22.2") == false)
        #expect(offered.contains("v22.12.0"))
    }

    /// A hand-edited alias file can point at itself. Without a seen-set this
    /// loops forever in the middle of a scan.
    @Test func aCyclicAliasTerminatesRatherThanHanging() {
        let offered = stale(pointer: "a", aliases: ["a": "b", "b": "a"])
        #expect(offered.contains("v24.13.0") == false)
        #expect(offered.count == installed.count - 1)
    }

    /// A partial version selects the highest match, and must not select
    /// v22.12.0 over v22.22.2 by string order.
    @Test func aPartialVersionSelectsTheHighestMatchingInstall() {
        #expect(ToolchainVersions.resolve("22", in: installed.map(\.lastPathComponent),
            resolveAlias: { _ in nil }) == "v22.22.2")
    }

    /// The rule that outranks every inference: something is running out of it
    /// right now.
    @Test func aVersionWithALiveProcessIsRetainedHoweverOldItIs() {
        let offered = stale(running: ["/Users/x/.nvm/versions/node/v18.16.0/bin/node"])
        #expect(offered.contains("v18.16.0") == false)
    }

    /// Path components, not string prefixes: `v20.1` must not be considered
    /// running because a process lives under `v20.13.1`.
    @Test func aRunningVersionDoesNotRetainItsStringPrefixNeighbours() {
        let offered = stale(running: ["/Users/x/.nvm/versions/node/v20.13.1/bin/node"])
        #expect(offered.contains("v20.13.1") == false)
        #expect(offered.contains("v20.11.0"))
        #expect(offered.contains("v20.12.2"))
    }

    /// A process elsewhere on disk retains nothing — a Homebrew node was live
    /// on this machine alongside the nvm ones.
    @Test func aProcessOutsideTheVersionsRootRetainsNothing() {
        let offered = stale(running: ["/usr/local/Cellar/node/23.3.0/bin/node"])
        #expect(offered.count == installed.count - 1)
    }

    /// One install cannot be stale: it is the newest by definition.
    @Test func aSingleInstalledVersionIsNeverOffered() {
        let one = [URL(fileURLWithPath: "/Users/x/.nvm/versions/node/v24.13.0", isDirectory: true)]
        #expect(
            ToolchainVersions.stale(
                among: one, pointer: nil, resolveAlias: { _ in nil }, runningExecutables: []
            ).isEmpty)
    }

    @Test func noInstalledVersionsRetainsNothingAndOffersNothing() {
        #expect(
            ToolchainVersions.stale(
                among: [], pointer: "node", resolveAlias: { _ in nil }, runningExecutables: []
            ).isEmpty)
    }
}

/// A process list that could not be enumerated must offer nothing.
///
/// `proc_listpids` returning zero is not "no processes are running" — it is
/// "this could not be asked", and the two arrive as the same empty array. The
/// live-process rule is the one the other two defer to, because a version
/// something is running out of is in use whatever any alias claims. Skipped
/// silently, every version but the newest and the pointer's target is offered
/// while a dev server is running out of one of them.
///
/// The other retentions still hold, which is what makes this dangerous rather
/// than obvious: the result looks like a plausible short list, not like a
/// failure.
@Test func aProcessListThatCouldNotBeEnumeratedOffersNothing() {
    let installed = ["v18.16.0", "v20.13.1", "v24.13.0"]
        .map { URL(fileURLWithPath: "/Users/x/.nvm/versions/node/\($0)", isDirectory: true) }

    // Read, and holding nothing relevant: the miss is real, so the older two
    // are offered. Without this the assertion below could pass over a rule
    // that had simply stopped offering anything.
    #expect(ToolchainVersions.stale(
        among: installed, pointer: nil, resolveAlias: { _ in nil },
        runningExecutables: []).map(\.lastPathComponent) == ["v18.16.0", "v20.13.1"])

    // Could not be read: nothing is offered, because rule 3 never ran.
    #expect(ToolchainVersions.stale(
        among: installed, pointer: nil, resolveAlias: { _ in nil },
        runningExecutables: nil).isEmpty)
}

/// The enumeration has to actually see processes. A version of this that
/// silently returned an empty array would pass every retention test above —
/// they inject their own process list — while removing the one retention that
/// outranks the others on a real machine.
@Test func runningExecutablesSeesAtLeastThisProcess() throws {
    // Non-nil first: `nil` is the "could not enumerate" answer, and every
    // retention below it would be skipped rather than applied.
    let enumerated = try #require(RunningExecutables.current())
    let paths = enumerated.map(\.path)
    #expect(paths.isEmpty == false)
    // This test process is itself running, so its own executable must be in
    // the list; anything less means the call is returning something other than
    // what this machine is running.
    let own = ProcessInfo.processInfo.arguments.first.map {
        URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
    }
    if let own { #expect(paths.contains { $0.hasSuffix(URL(fileURLWithPath: own).lastPathComponent) }) }
}

/// End to end through `FileScanner`, against a fixture home. The retention
/// rules are unit-tested above; this asserts the pattern is actually wired to
/// them — a `.toolchainVersions` entry that enumerated every version would
/// pass every test in this file except this one.
@Test func theScannerOffersStaleVersionsAndKeepsTheCurrentOne() async throws {
    try await withTempDirectory { home in
        let tree = FixtureTree(root: home)
        for version in ["v18.16.0", "v20.13.1", "v24.13.0"] {
            try tree.file(".nvm/versions/node/\(version)/bin/node", byteCount: 2_000_000)
        }
        try tree.file(".nvm/alias/default")
        try "node".write(
            to: home.appending(path: ".nvm/alias/default"), atomically: true, encoding: .utf8)

        let profile = ScanProfile(
            category: .nodeJS,
            patterns: [
                .toolchainVersions(
                    under: "~/.nvm/versions/node", pointer: "~/.nvm/alias/default",
                    aliases: "~/.nvm/alias", tier: .costly)
            ])

        let report = await FileScanner().discoverPathPatterns(
            profiles: [profile], home: home, runningExecutables: { [] })
        let offered = report.candidates.map { $0.path.lastPathComponent }.sorted()

        #expect(offered == ["v18.16.0", "v20.13.1"])
        #expect(report.candidates.allSatisfy { $0.tier == .costly })
    }
}

/// The retention that outranks the others, end to end: a live process keeps
/// its version out of the results even though it is neither newest nor
/// pointed at.
@Test func theScannerKeepsAVersionSomethingIsRunning() async throws {
    try await withTempDirectory { home in
        let tree = FixtureTree(root: home)
        for version in ["v18.16.0", "v20.13.1", "v24.13.0"] {
            try tree.file(".nvm/versions/node/\(version)/bin/node", byteCount: 2_000_000)
        }
        let live = home.appending(path: ".nvm/versions/node/v18.16.0/bin/node")

        let profile = ScanProfile(
            category: .nodeJS,
            patterns: [.toolchainVersions(under: "~/.nvm/versions/node", tier: .costly)])

        let report = await FileScanner().discoverPathPatterns(
            profiles: [profile], home: home, runningExecutables: { [live] })

        #expect(report.candidates.map { $0.path.lastPathComponent } == ["v20.13.1"])
    }
}

/// A pointer file that exists and will not open must stop the sweep offering,
/// not be read as a manager that points nowhere.
///
/// `try? String(contentsOf:)` gave both the same `nil`, so an unreadable
/// `default` alias let every version but the newest be offered — including the
/// one the manager points straight at. Absent is the common case and stays
/// fine: most managers declare a pointer path they have not written.
///
/// The versions are refused rather than silently dropped, so the sweep's total
/// reads as a floor instead of quietly shrinking.
@Test func theScannerOffersNothingWhenAPointerFileWillNotOpen() async throws {
    guard getuid() != 0 else { return }  // root can read a 000 file
    try await withTempDirectory { home in
        let tree = FixtureTree(root: home)
        for version in ["v18.16.0", "v20.13.1", "v24.13.0"] {
            try tree.file(".nvm/versions/node/\(version)/bin/node", byteCount: 2_000_000)
        }
        try tree.file(".nvm/alias/default")
        let pointer = home.appending(path: ".nvm/alias/default")
        try "v20.13.1".write(to: pointer, atomically: true, encoding: .utf8)

        let profile = ScanProfile(
            category: .nodeJS,
            patterns: [
                .toolchainVersions(
                    under: "~/.nvm/versions/node", pointer: "~/.nvm/alias/default",
                    aliases: "~/.nvm/alias", tier: .costly)
            ])

        // Readable: the pointer retains v20.13.1 and the oldest is offered.
        // Without this the assertion below could pass over a fixture that
        // never offered anything.
        let readable = await FileScanner().discoverPathPatterns(
            profiles: [profile], home: home, runningExecutables: { [] })
        #expect(readable.candidates.map { $0.path.lastPathComponent } == ["v18.16.0"])

        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: pointer.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: pointer.path)
        }

        let blocked = await FileScanner().discoverPathPatterns(
            profiles: [profile], home: home, runningExecutables: { [] })
        #expect(blocked.candidates.isEmpty)
        #expect(blocked.refusals.paths.isEmpty == false)
    }
}

/// The same gate for the process list, end to end. `stale` is unit-tested for
/// it above; this pins that the scanner passes the real answer through rather
/// than substituting an empty list of its own.
@Test func theScannerOffersNothingWhenTheProcessListCannotBeEnumerated() async throws {
    try await withTempDirectory { home in
        let tree = FixtureTree(root: home)
        for version in ["v18.16.0", "v20.13.1", "v24.13.0"] {
            try tree.file(".nvm/versions/node/\(version)/bin/node", byteCount: 2_000_000)
        }
        let profile = ScanProfile(
            category: .nodeJS,
            patterns: [.toolchainVersions(under: "~/.nvm/versions/node", tier: .costly)])

        let enumerated = await FileScanner().discoverPathPatterns(
            profiles: [profile], home: home, runningExecutables: { [] })
        #expect(enumerated.candidates.isEmpty == false)

        let unavailable = await FileScanner().discoverPathPatterns(
            profiles: [profile], home: home, runningExecutables: { nil })
        #expect(unavailable.candidates.isEmpty)
    }
}
