import Testing
import Foundation
@testable import HelpBookGen

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func buildBook() throws -> URL {
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-help-\(UUID().uuidString)")
        .appending(path: HelpBookConstants.folderName)
    let writer = BundleWriter(
        pagesDirectory: packageRoot.appending(path: "Help/pages"),
        generatedDirectory: packageRoot.appending(path: "Help/generated"),
        styleSheet: packageRoot.appending(path: "Help/style.css")
    )
    try writer.write(to: destination)
    return destination
}

@Test func theBundleHasTheStructureHelpViewerExpects() throws {
    let book = try buildBook()
    let resources = book.appending(path: "Contents/Resources/en.lproj")
    #expect(FileManager.default.fileExists(atPath: book.appending(path: "Contents/Info.plist").path))
    #expect(FileManager.default.fileExists(atPath: resources.appending(path: "index.html").path))
    #expect(FileManager.default.fileExists(atPath: resources.appending(path: "reference-tiers.html").path))
    #expect(FileManager.default.fileExists(atPath: resources.appending(path: "style.css").path))
}

/// A CFBundleHelpBookName that disagrees with the index page's AppleTitle
/// opens an empty Help window with no error at all.
@Test func theIndexPageCarriesTheBookNameAsItsAppleTitle() throws {
    let book = try buildBook()
    let index = try String(
        contentsOf: book.appending(path: "Contents/Resources/en.lproj/index.html"),
        encoding: .utf8
    )
    #expect(index.contains("<meta name=\"AppleTitle\" content=\"\(HelpBookConstants.bookName)\">"))
}

@Test func everyPageCarriesItsOwnAppleTitle() throws {
    let book = try buildBook()
    let page = try String(
        contentsOf: book.appending(path: "Contents/Resources/en.lproj/reference-tiers.html"),
        encoding: .utf8
    )
    #expect(page.contains("<meta name=\"AppleTitle\" content=\"The three tiers\">"))
}

@Test func theHelpPlistDeclaresTheKeysHelpViewerReads() throws {
    let book = try buildBook()
    let data = try Data(contentsOf: book.appending(path: "Contents/Info.plist"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    #expect(plist["CFBundleIdentifier"] as? String == HelpBookConstants.bundleIdentifier)
    #expect(plist["HPDBookTitle"] as? String == HelpBookConstants.bookName)
    #expect(plist["HPDBookType"] as? String == "3")
    #expect(plist["HPDBookAccessPath"] as? String == "index.html")
    #expect(plist["HPDBookIndexPath"] as? String == HelpBookConstants.indexFilename)
}

@Test func generatedAnchorsSurviveIntoTheHTML() throws {
    let book = try buildBook()
    let page = try String(
        contentsOf: book.appending(path: "Contents/Resources/en.lproj/reference-categories.html"),
        encoding: .utf8
    )
    #expect(page.contains("<a name=\"category-nodejs\"></a>"))
}

/// Before this, a leaf page carried no navigation markup at all — not a
/// sidebar, not a link back to the contents. Help Viewer's back button was the
/// only way out of any page reached from search.
@Test func everyPageCarriesTheTopicsNav() throws {
    let book = try buildBook()
    let resources = book.appending(path: "Contents/Resources/en.lproj")

    for name in Navigation.all {
        let page = try String(contentsOf: resources.appending(path: "\(name).html"), encoding: .utf8)
        #expect(page.contains("<nav class=\"topics\">"), "\(name).html has no nav")
        for other in Navigation.all where other != name {
            #expect(page.contains("href=\"\(other).html\""),
                    "\(name).html's nav does not link to \(other).html")
        }
    }
}

/// A nav that links the page you are already on wastes the one affordance that
/// tells you where you are.
@Test func theCurrentPageIsNamedInTheNavButNotLinkedToItself() throws {
    let book = try buildBook()
    let page = try String(
        contentsOf: book.appending(path: "Contents/Resources/en.lproj/privacy.html"),
        encoding: .utf8
    )
    #expect(page.contains("aria-current=\"page\""))
    #expect(!page.contains("href=\"privacy.html\""),
            "privacy.html links to itself in its own nav")
}

/// The writer walks both Markdown directories alphabetically. Reading order is
/// not alphabetical, so this fails the moment the nav is built from the sort
/// rather than from `Navigation`: alphabetically "files-view" precedes
/// "what-ddcc-does", and in the book it does not.
///
/// Deliberately read from `privacy.html`, not `index.html`. The index page
/// authors its own links in Markdown, so it would satisfy this ordering even
/// with no nav generated at all — it passed exactly that way when first
/// written. A leaf page has no links of its own, so only the nav can supply
/// these two.
@Test func theNavPresentsPagesInEditorialOrderNotAlphabetical() throws {
    let book = try buildBook()
    let page = try String(
        contentsOf: book.appending(path: "Contents/Resources/en.lproj/privacy.html"),
        encoding: .utf8
    )
    guard let first = page.range(of: "href=\"what-ddcc-does.html\""),
          let later = page.range(of: "href=\"files-view.html\"") else {
        Issue.record("nav is missing the links this test orders")
        return
    }
    #expect(first.lowerBound < later.lowerBound)
}

/// Both directories are flattened into one `en.lproj`, so a name in both used
/// to mean the second silently overwrote the first — no error, no warning, one
/// page just quietly gone from a book that still built and still passed.
@Test func aNameUsedInBothDirectoriesIsRejectedRatherThanOverwritten() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-help-clash-\(UUID().uuidString)")
    let pages = root.appending(path: "pages")
    let generated = root.appending(path: "generated")
    try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)

    try "# Authored\n\nOne.\n".write(to: pages.appending(path: "clash.md"),
                                    atomically: true, encoding: .utf8)
    try "# Generated\n\nTwo.\n".write(to: generated.appending(path: "clash.md"),
                                     atomically: true, encoding: .utf8)

    let writer = BundleWriter(
        pagesDirectory: pages,
        generatedDirectory: generated,
        styleSheet: packageRoot.appending(path: "Help/style.css")
    )
    #expect(throws: BundleWriterError.duplicatePageName("clash")) {
        try writer.write(to: root.appending(path: "Built.help"))
    }
}

/// A heading with `& < > "` must not be able to break out of the `content="..."`
/// attribute or the `<title>` element the way it would if interpolated raw.
/// The identical string is already escaped when it appears in the body via
/// MarkdownSubset; the title path must get the same guarantee.
@Test func theTitleIsEscapedLikeAnyOtherPageContent() throws {
    let pagesDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-help-title-\(UUID().uuidString)")
    let generatedDirectory = pagesDirectory.appending(path: "generated")
    try FileManager.default.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)

    let heading = #"A "><script>alert(1)</script>"#
    let markdown = "# \(heading)\n\nBody text.\n"
    try markdown.write(
        to: pagesDirectory.appending(path: "dangerous.md"),
        atomically: true, encoding: .utf8
    )

    let destination = pagesDirectory.appending(path: "Built.help")
    let writer = BundleWriter(
        pagesDirectory: pagesDirectory,
        generatedDirectory: generatedDirectory,
        styleSheet: packageRoot.appending(path: "Help/style.css")
    )
    try writer.write(to: destination)

    let page = try String(
        contentsOf: destination.appending(path: "Contents/Resources/en.lproj/dangerous.html"),
        encoding: .utf8
    )

    let escaped = "A &quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;"
    #expect(page.contains("<meta name=\"AppleTitle\" content=\"\(escaped)\">"))
    #expect(page.contains("<title>\(escaped)</title>"))
    #expect(!page.contains("<script>alert(1)</script>"))
    #expect(!page.contains("content=\"A \">"))
}
