import Foundation

/// How a path is shown to a person.
///
/// One implementation, because there were two: `ScanResult.relativePath` and
/// `FoundFile.relativePath` held byte-identical copies of the same unanchored
/// `replacingOccurrences(of: home, with: "~/")`, which rewrote the home path
/// wherever it appeared rather than only at the front.
///
/// Note the contrast with `PathGuard.normalizedPathString`, which duplicates
/// `Candidate.normalizedPathKey` **deliberately**, so the safety backstop does
/// not depend on `Models`, with tests pinning the two in agreement. That
/// argument is about a guard; this is a display string, and nobody should
/// generalise from one to the other.
public enum PathDisplay {

    /// `url` with the home directory replaced by `~`, or unchanged if `url` is
    /// not inside `home`.
    ///
    /// Anchored at the front and matched at a path-component boundary, so a
    /// sibling home whose name merely extends this one (`/Users/janefoo` beside
    /// `/Users/jane`) is left alone. `home` is a parameter so tests can fix it
    /// rather than depend on whoever runs them.
    public static func tildeAbbreviated(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var path = url.path(percentEncoded: false)
        var root = home.path(percentEncoded: false)
        // `homeDirectoryForCurrentUser` has returned both spellings across OS
        // versions, and the old code's boundary safety rested entirely on the
        // trailing slash happening to be there. `url` can carry the same
        // ambiguity (a directory URL built with `isDirectory: true`), so both
        // sides are normalized the same way before comparing.
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        if path == root { return "~" }
        guard path.hasPrefix(root + "/") else { return path }
        return "~/" + path.dropFirst(root.count + 1)
    }

    /// The same abbreviation for a path already held as a string.
    ///
    /// `DisclosedPath` stores text, not a `URL`. Without this the call site
    /// rebuilds a `URL` inline, which is how the two spellings drifted apart
    /// the first time.
    ///
    /// `isDirectory: false` is passed so the conversion never touches the
    /// filesystem; a display string must not depend on whether the path
    /// still exists.
    public static func tildeAbbreviated(
        _ path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        tildeAbbreviated(URL(fileURLWithPath: path, isDirectory: false), home: home)
    }

    /// `path` abbreviated only if it is absolute, and returned untouched
    /// otherwise.
    ///
    /// Call sites that hold a display string rather than a known path need
    /// this: the scanning footer also carries "Starting…", and a dead
    /// artifact's target is whatever a manifest declared. Passing a relative
    /// string to `URL(fileURLWithPath:)` resolves it against the working
    /// directory, so "Starting…" would render as a path inside whatever
    /// folder the app was launched from.
    public static func tildeAbbreviatedIfAbsolute(
        _ path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        path.hasPrefix("/") ? tildeAbbreviated(path, home: home) : path
    }
}
