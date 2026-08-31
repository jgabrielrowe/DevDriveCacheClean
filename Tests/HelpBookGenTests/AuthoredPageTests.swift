import Testing
import Foundation
@testable import HelpBookGen

private var pagesDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Help/pages")
}

private var generatedDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Help/generated")
}

private let expectedPages = [
    "index.md", "what-ddcc-does.md", "honest-number.md", "unlocking-tiers.md",
    "first-scan.md", "files-view.md", "trash-not-delete.md",
    "full-disk-access.md", "privacy.md",
]

@Test func everyAuthoredPageExists() throws {
    for name in expectedPages {
        let url = pagesDirectory.appending(path: name)
        #expect(FileManager.default.fileExists(atPath: url.path), "Help/pages/\(name) is missing")
    }
}

/// A page whose Markdown the converter rejects would fail the build at bundle
/// assembly with a far less obvious message than this one.
@Test func everyAuthoredPageConverts() throws {
    for name in expectedPages {
        let source = try String(contentsOf: pagesDirectory.appending(path: name), encoding: .utf8)
        #expect(throws: Never.self, "Help/pages/\(name) does not convert") {
            try MarkdownSubset.html(from: source)
        }
    }
}

/// The first line becomes the page's AppleTitle. Without one, Help Viewer
/// shows the filename in search results.
@Test func everyAuthoredPageOpensWithAnH1() throws {
    for name in expectedPages {
        let source = try String(contentsOf: pagesDirectory.appending(path: name), encoding: .utf8)
        let first = source.components(separatedBy: .newlines).first ?? ""
        #expect(first.hasPrefix("# "), "Help/pages/\(name) must start with a '# ' heading, got: \(first)")
    }
}

/// A dead link on the book's front page is invisible until someone clicks
/// it. This walks every Markdown file in both `Help/pages/` (authored) and
/// `Help/generated/` (the reference pages, which can carry links too) and
/// confirms each `[label](target.html)` link resolves to a `target.md` that
/// exists in one of those two directories — the pair `BundleWriter` renders
/// every `.md` in this book from.
@Test func everyLinkResolvesToAnExistingPage() throws {
    let directories = [pagesDirectory, generatedDirectory]
    let markdownFiles = try directories.flatMap { directory in
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    let linkPattern = try NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
    var checked = 0

    for fileURL in markdownFiles {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        let matches = linkPattern.matches(in: source, range: range)

        for match in matches {
            guard let labelRange = Range(match.range(at: 1), in: source),
                  let targetRange = Range(match.range(at: 2), in: source) else { continue }
            let label = String(source[labelRange])
            let target = String(source[targetRange])
            guard target.hasSuffix(".html") else { continue }
            checked += 1

            let targetName = String(target.dropLast(".html".count)) + ".md"
            let resolves = directories.contains {
                FileManager.default.fileExists(atPath: $0.appending(path: targetName).path)
            }
            #expect(
                resolves,
                "\(fileURL.lastPathComponent): link \"\(label)\" points at \(target), but \(targetName) does not exist in Help/pages or Help/generated"
            )
        }
    }

    // Without this the test approves the book by finding nothing to check: a
    // regex that stops matching, or a rename of the Help directories, reports
    // success just as loudly as a book with every link intact. The count is
    // low and deliberately so — the nav's links are generated in Swift now,
    // not authored in Markdown, and `NavigationTests` is what guards those.
    #expect(checked > 0, "no Markdown links were examined, so this proved nothing")
}
