import Foundation

/// Thrown when the indexing process itself fails. Must never be swallowed:
/// a stale or missing index still opens and still looks like a working help
/// book, it just answers every search and anchor lookup wrong.
public enum HelpIndexError: Error, Equatable {
    case nonZeroExit(Int32)
}

/// The `hiutil` invocation, kept in one place so a test can assert `-a`
/// survives, and run from exactly this one place so the tested argument
/// list and the executed argument list can never diverge again.
public enum HelpIndex {
    public static let tool = "/usr/bin/hiutil"

    public static func arguments(forBookAt path: String) -> [String] {
        let lproj = "\(path)/Contents/Resources/\(HelpBookConstants.language).lproj"
        return [
            "-I", "corespotlight",
            "-C",
            "-a",                                   // index anchors; NOT the default
            "-s", HelpBookConstants.language,       // stopwords
            "-f", "\(lproj)/\(HelpBookConstants.indexFilename)",
            lproj,
        ]
    }

    /// Runs the indexer against a freshly written help book. `runner`
    /// defaults to a real process spawn; tests inject a recording stub so
    /// what actually gets invoked can be asserted without depending on
    /// hiutil's own behaviour.
    public static func index(
        bookAt path: String,
        runner: (_ tool: String, _ arguments: [String]) throws -> Void = spawnProcess
    ) throws {
        try runner(tool, arguments(forBookAt: path))
    }

    /// The real runner: spawns `tool` with `arguments` and throws if it
    /// exits non-zero. A silently-ignored failure here would leave a stale
    /// or absent index while the build reports success.
    public static func spawnProcess(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelpIndexError.nonZeroExit(process.terminationStatus)
        }
    }
}
