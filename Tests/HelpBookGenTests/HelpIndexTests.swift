import Testing
@testable import HelpBookGen

/// `-a` is NOT hiutil's default. Without it anchors are not indexed: the book
/// still opens, search still works, and every anchor lookup silently resolves
/// to nothing. hiutil has no query mode, so no check can interrogate
/// a built index — asserting the flag is still in the argument list is the
/// only coverage available short of launching the app.
@Test func theIndexerRequestsAnchorIndexing() {
    #expect(HelpIndex.arguments(forBookAt: "/tmp/DDCC.help").contains("-a"))
}

@Test func theIndexerTargetsTheLprojDirectoryAndWritesInsideIt() {
    let arguments = HelpIndex.arguments(forBookAt: "/tmp/DDCC.help")
    let lproj = "/tmp/DDCC.help/Contents/Resources/en.lproj"
    #expect(arguments.last == lproj)
    #expect(arguments.contains("\(lproj)/\(HelpBookConstants.indexFilename)"))
}

@Test func theIndexerBuildsACoreSpotlightIndex() {
    let arguments = HelpIndex.arguments(forBookAt: "/tmp/DDCC.help")
    #expect(arguments.contains("corespotlight"))
}

/// A second, hand-typed copy of this argument list in `make-app.sh` would
/// make the value these tests assert on and the value the build runs two
/// different things. `HelpIndex.index` is the one call site that
/// runs hiutil in production; asserting the recording stub sees exactly
/// `HelpIndex.tool` and `HelpIndex.arguments(forBookAt:)` is what would have
/// caught that divergence.
@Test func theBuildStepInvokesTheIndexerWithTheDeclaredToolAndArguments() throws {
    var recordedTool: String?
    var recordedArguments: [String]?
    try HelpIndex.index(bookAt: "/tmp/DDCC.help") { tool, arguments in
        recordedTool = tool
        recordedArguments = arguments
    }
    #expect(recordedTool == HelpIndex.tool)
    #expect(recordedArguments == HelpIndex.arguments(forBookAt: "/tmp/DDCC.help"))
}

@Test func theIndexerPropagatesAFailureFromTheRunner() {
    #expect(throws: HelpIndexError.self) {
        try HelpIndex.index(bookAt: "/tmp/DDCC.help") { _, _ in
            throw HelpIndexError.nonZeroExit(1)
        }
    }
}

/// The default runner is real `Process` spawning, decoupled here from
/// `hiutil` specifically so the exit-code check can be exercised without
/// depending on hiutil's own behaviour.
@Test func theDefaultRunnerThrowsWhenTheToolExitsNonZero() {
    #expect(throws: HelpIndexError.self) {
        try HelpIndex.spawnProcess("/usr/bin/false", [])
    }
}

@Test func theDefaultRunnerSucceedsWhenTheToolExitsZero() throws {
    try HelpIndex.spawnProcess("/usr/bin/true", [])
}
