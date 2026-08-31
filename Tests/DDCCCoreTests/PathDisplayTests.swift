import Testing
import Foundation
@testable import DDCCCore

/// `relativePath` used `replacingOccurrences(of: home, with: "~/")`, which is
/// unanchored: it rewrote the home path wherever it appeared, not only as a
/// prefix. With home `/Users/me`, `/Volumes/Backup/Users/me/big.bin` rendered
/// as `/Volumes/Backup~/big.bin`. Reachable today, since the Files view accepts
/// any folder as a scan root.
///
/// `home` is injected rather than read from the process so these cases are
/// fixed rather than dependent on whoever runs the suite.
private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

@Test func aChildOfHomeIsAbbreviated() {
    #expect(PathDisplay.tildeAbbreviated(
        URL(fileURLWithPath: "/Users/example/Projects/App.app"), home: home)
        == "~/Projects/App.app")
}

/// The measured defect.
@Test func aPathContainingHomeAsANonPrefixIsLeftAlone() {
    #expect(PathDisplay.tildeAbbreviated(
        URL(fileURLWithPath: "/Volumes/Backup/Users/example/big.bin"), home: home)
        == "/Volumes/Backup/Users/example/big.bin")
}

/// The boundary case. `/Users/examplefoo` is a different user's home and shares
/// a string prefix with this one. It survives today only because
/// `homeDirectoryForCurrentUser` happens to return a trailing slash on this OS
/// version — nothing in the code asserts that, so the replacement must not
/// depend on it.
@Test func aSiblingWhoseNameExtendsHomeIsLeftAlone() {
    #expect(PathDisplay.tildeAbbreviated(
        URL(fileURLWithPath: "/Users/examplefoo/x.bin"), home: home)
        == "/Users/examplefoo/x.bin")
}

/// The home directory itself, which the old code did not abbreviate at all.
@Test func theHomeDirectoryItselfIsAbbreviated() {
    #expect(PathDisplay.tildeAbbreviated(
        URL(fileURLWithPath: "/Users/example", isDirectory: true), home: home) == "~")
}

@Test func aPathSharingNoPrefixWithHomeIsLeftAlone() {
    #expect(PathDisplay.tildeAbbreviated(
        URL(fileURLWithPath: "/opt/homebrew/Cellar"), home: home) == "/opt/homebrew/Cellar")
}

/// A home path that arrives with a trailing slash and one that does not must
/// produce the same answer, since `homeDirectoryForCurrentUser` has returned
/// both spellings across OS versions.
@Test func aTrailingSlashOnHomeDoesNotChangeTheResult() {
    let withSlash = URL(fileURLWithPath: "/Users/example/", isDirectory: true)
    let target = URL(fileURLWithPath: "/Users/example/Projects/App.app")
    #expect(PathDisplay.tildeAbbreviated(target, home: withSlash)
        == PathDisplay.tildeAbbreviated(target, home: home))
}

/// The two models must not drift apart again: they held byte-identical copies
/// of the broken line, so fixing one and not the other is the obvious way for
/// this to half-regress.
@Test func bothModelsAbbreviateThroughTheSameHelper() {
    let path = URL(fileURLWithPath: "/Volumes/Backup/Users/me/big.bin")
    let found = FoundFile(path: path, sizeBytes: 1, lastModified: nil, isBundle: false)
    let scan = ScanResult(
        path: path, category: .xcode, tier: .safe, removability: .removable,
        sizeBytes: 1, lastModified: nil, displayName: "x",
        partialRead: false, unreadablePaths: [], isDeletable: true)

    #expect(found.relativePath == scan.relativePath)
    #expect(found.relativePath == PathDisplay.tildeAbbreviated(path))
}

/// `DisclosedPath` holds text, so the string overload is what the uninstall
/// disclosure lists actually call.
@Test func aStringInsideHomeIsAbbreviated() {
    let home = URL(fileURLWithPath: "/Users/example")
    #expect(PathDisplay.tildeAbbreviated("/Users/example/Library/Caches/x", home: home)
            == "~/Library/Caches/x")
}

@Test func aStringOutsideHomeIsLeftAlone() {
    let home = URL(fileURLWithPath: "/Users/example")
    #expect(PathDisplay.tildeAbbreviated("/Library/Application Support/x", home: home)
            == "/Library/Application Support/x")
}

/// The point of the overload is that there is still one implementation.
@Test func theStringAndURLOverloadsAgree() {
    let home = URL(fileURLWithPath: "/Users/example")
    for path in ["/Users/example", "/Users/example/", "/Users/exampleother/x",
                 "/Users/example/a b/c", "/", "/opt/homebrew"] {
        #expect(PathDisplay.tildeAbbreviated(path, home: home)
                == PathDisplay.tildeAbbreviated(URL(fileURLWithPath: path, isDirectory: false), home: home),
                "disagreed on \(path)")
    }
}

/// The "only if absolute" rule, which three call sites need: the scanning
/// footer, the finder's progress line, and a dead artifact's target.
@Test func onlyAnAbsolutePathIsAbbreviated() {
    let home = URL(fileURLWithPath: "/Users/example")
    #expect(PathDisplay.tildeAbbreviatedIfAbsolute("/Users/example/Library/x", home: home)
            == "~/Library/x")
    #expect(PathDisplay.tildeAbbreviatedIfAbsolute("/Library/x", home: home) == "/Library/x")
}

/// The trap the rule exists for. Without it, "Starting…" becomes a path
/// inside whatever directory the app happened to be launched from.
@Test func aStringThatIsNotAPathIsLeftAlone() {
    let home = URL(fileURLWithPath: "/Users/example")
    for text in ["Starting…", "Resolving overlaps…", "Analyzing org.videolan.vlc…"] {
        #expect(PathDisplay.tildeAbbreviatedIfAbsolute(text, home: home) == text)
    }
}
