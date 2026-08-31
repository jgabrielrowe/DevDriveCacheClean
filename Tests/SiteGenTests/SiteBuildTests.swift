import Testing
import Foundation
import CryptoKit
@testable import SiteGen
import DDCCCore

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SiteGenTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
}

private func writer() -> SiteWriter {
    SiteWriter(sourceRoot: repoRoot().appending(path: "Site"),
               helpRoot: repoRoot().appending(path: "Help"))
}

/// The real site, built once for the whole suite rather than once per
/// assertion. `Result` makes the memoisation lazy and thread-safe, and lets
/// every call site keep failing through its own `#require` message instead of
/// crashing the process if the build itself is broken.
private enum BuiltSite {
    static let files = Result { try writer().files() }
}

private func builtFiles() throws -> [String: Data] {
    try BuiltSite.files.get()
}

/// Every occurrence of `open`…`close`, non-overlapping and in order.
private func innerTexts(_ text: String, _ open: String, _ close: String) -> [String] {
    var out: [String] = []
    var rest = Substring(text)
    while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
        out.append(String(rest[start.upperBound..<end.lowerBound]))
        rest = rest[end.upperBound...]
    }
    return out
}

/// Every capture group 1 of `pattern` found in `text`.
private func captures(_ text: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
}

/// docs/ is what GitHub Pages serves, so it must match a fresh build byte for byte.
@Test func theCommittedSiteMatchesTheBuilder() throws {
    let drift = try writer().drift(against: repoRoot().appending(path: "docs"))
    #expect(drift.isEmpty, "run `swift run SiteBuilder`: \(drift.joined(separator: ", "))")
}

/// The shipped fonts are subset. A copy edit that introduces a character
/// outside that subset must fail the build loudly instead of shipping tofu —
/// this is the guard that makes that true.
@Test func theBuiltSiteUsesNoCharacterTheShippedFontsLack() throws {
    try writer().verifyFontCoverage()
}

/// A page with no title or description is refused rather than rendered.
@Test func aPageWithoutMetadataIsRefused() throws {
    let shell = Shell(template: "<title>{{title}}</title>{{description}}{{canonical}}{{ogImage}}{{root}}{{head}}{{body}}{{nav}}{{crumb}}")
    #expect(throws: ShellError.missingMetadata(page: "index.html", field: "title")) {
        try shell.render(SitePage(slug: "", title: "", description: "d", body: "b"))
    }
    #expect(throws: ShellError.missingMetadata(page: "x/index.html", field: "description")) {
        try shell.render(SitePage(slug: "x/", title: "t", description: "", body: "b"))
    }
}

/// An unknown placeholder fails the build rather than shipping `{{…}}`.
@Test func anUnknownPlaceholderIsFatal() {
    let shell = Shell(template: "{{title}}{{description}}{{canonical}}{{ogImage}}{{root}}{{head}}{{body}}{{nav}}{{crumb}}{{invented}}")
    #expect(throws: ShellError.unresolvedPlaceholder(page: "index.html", name: "{{invented}}")) {
        try shell.render(SitePage(slug: "", title: "t", description: "d", body: "b"))
    }
}

/// Asset paths are relative, so the built site can be opened from disk. That
/// only works if depth is computed rather than assumed.
@Test func theRootPrefixFollowsTheDepth() {
    #expect(SitePage(slug: "", title: "t", description: "d", body: "").rootPrefix == "")
    #expect(SitePage(slug: "uninstall/", title: "t", description: "d", body: "").rootPrefix == "../")
    #expect(SitePage(slug: "user-guide/privacy/", title: "t", description: "d", body: "").rootPrefix == "../../")
}

/// Every page reaches the stylesheet, carries a canonical, and marks its place in the
/// masthead.
@Test func everyPageLinksItsAssetsAndMarksItsPlace() throws {
    let files = try builtFiles()
    let pages = files.filter { $0.key.hasSuffix(".html") }
    try #require(pages.count >= 15, "only \(pages.count) pages; this test would prove little")

    for (path, data) in pages {
        let html = String(decoding: data, as: UTF8.self)
        // The 404 is served in response to a request for any path, so its
        // asset links must be site-absolute; everything else is relative so
        // the built site opens from disk.
        let depth = path.split(separator: "/").count - 1
        let prefix = path == "404.html" ? "/" : String(repeating: "../", count: depth)
        #expect(html.contains("href=\"\(prefix)assets/css/site.css\""), "\(path) cannot reach the stylesheet")
        #expect(html.contains("<link rel=\"canonical\""), "\(path) has no canonical")
        #expect(!html.contains("{{"), "\(path) shipped an unresolved placeholder")
    }

    // Bounded to the masthead: a breadcrumb leaf carries aria-current of its own.
    let privacyPage = try #require(files["user-guide/privacy/index.html"], "the privacy guide page was not built")
    let doc = String(decoding: privacyPage, as: UTF8.self)
    let mastheadNav = try #require(window(in: doc, from: "<nav>", to: "</nav>"),
                                   "the masthead has no nav; this test would prove nothing")
    #expect(mastheadNav.components(separatedBy: "aria-current").count - 1 == 1,
            "the masthead marks \(mastheadNav.components(separatedBy: "aria-current").count - 1) entries current")
    #expect(mastheadNav.contains("User Guide"), "the masthead does not mark the User Guide entry")
}

/// Every asset a built page or the stylesheet names must exist. Both HTML references
/// and the stylesheet's url() rules are read.
@Test func everyAssetAPageNamesExists() throws {
    let assets = repoRoot().appending(path: "Site/assets")
    var referenced: Set<String> = []

    // Both relative and absolute references carry `assets/`; the path after it is what
    // matters.
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        for value in captures(String(decoding: data, as: UTF8.self),
                              #"(?:href|src|content)="([^"]*assets/[^"]*)""#) {
            guard let start = value.range(of: "assets/") else { continue }
            referenced.insert(String(value[start.upperBound...]))
        }
    }

    let css = try String(contentsOf: assets.appending(path: "css/site.css"), encoding: .utf8)
    for value in captures(css, #"url\("([^"]+)"\)"#) where !value.hasPrefix("data:") {
        // Relative to the stylesheet, which lives one directory down.
        let resolved = assets.appending(path: "css").appending(path: value).standardizedFileURL
        referenced.insert(String(resolved.path.dropFirst(assets.standardizedFileURL.path.count + 1)))
    }

    try #require(referenced.count >= 10,
                 "only \(referenced.count) assets named; this test would prove little")
    for name in referenced.sorted() {
        #expect(FileManager.default.fileExists(atPath: assets.appending(path: name).path),
                "Site/assets/\(name) is named by the built site and does not exist")
    }
}

/// The export must carry no HTML entities: `PlainText.unescaped` decodes by name, so
/// anything unlisted survives. Asserted as a class, not a list, so it cannot drift from
/// that list.
@Test func thePlainTextExportDecodesEveryEntity() throws {
    let files = try builtFiles()
    let export = try #require(files["llms-full.txt"], "there is no plain-text export to check")
    let text = String(decoding: export, as: UTF8.self)

    let pattern = #"&(?:[a-zA-Z][a-zA-Z0-9]{1,31}|#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6});"#
    let re = try NSRegularExpression(pattern: pattern)
    let found = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        .compactMap { Range($0.range, in: text).map { String(text[$0]) } }

    #expect(found.isEmpty,
            "the export carries undecoded entities: \(Set(found).sorted().joined(separator: " "))")
}

/// Every internal `href` a built page draws must resolve to a page the
/// builder actually produces. The masthead, the footer, and the guide's own
/// previous/next and contents links are all checked the same way; none of
/// them is hard-coded here. This is the defect class that can break every
/// page on the site at once from a single typo.
@Test func everyInternalLinkResolvesToABuiltPage() throws {
    let files = try builtFiles()

    func directory(of outputPath: String) -> [String] {
        var comps = outputPath.split(separator: "/").map(String.init)
        comps.removeLast()
        return comps
    }

    func resolve(_ href: String, from pageDirectory: [String]) -> String {
        var comps = href.hasPrefix("/") ? [] : pageDirectory
        for part in href.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { if !comps.isEmpty { comps.removeLast() } }
            else { comps.append(String(part)) }
        }
        let joined = comps.joined(separator: "/")
        return href.hasSuffix("/") || href.isEmpty
            ? (joined.isEmpty ? "index.html" : "\(joined)/index.html")
            : joined
    }

    var checked = 0
    for (path, data) in files where path.hasSuffix(".html") {
        let html = String(decoding: data, as: UTF8.self)
        let directory = directory(of: path)
        for href in captures(html, #"href="([^"]+)""#) {
            guard !href.contains("://"), !href.hasPrefix("mailto:"),
                  !href.hasPrefix("#"), !href.contains("assets/")
            else { continue }
            let target = resolve(href, from: directory)
            #expect(files[target] != nil,
                    "\(path) links to \"\(href)\", which resolves to \(target), a page the builder does not produce")
            checked += 1
        }
    }
    #expect(checked > 100, "only \(checked) internal links checked; this test would prove little")
}

/// The text between the first `from` and the next `to` after it.
private func window(in text: String, from: String, to: String) -> String? {
    guard let start = text.range(of: from),
          let end = text.range(of: to, range: start.upperBound..<text.endIndex)
    else { return nil }
    return String(text[start.upperBound..<end.lowerBound])
}

/// The sitemap lists absolute URLs, sorted, so two builds of an unchanged site
/// are byte-identical and the drift test means something.
@Test func theSitemapIsCompleteAndOrdered() throws {
    let files = try builtFiles()
    let sitemapData = try #require(files["sitemap.xml"], "sitemap.xml was not built")
    let sitemap = String(decoding: sitemapData, as: UTF8.self)
    let locs = sitemap.components(separatedBy: "<loc>").dropFirst().map {
        String($0.prefix(while: { $0 != "<" }))
    }
    #expect(locs == locs.sorted(), "sitemap order is unstable")
    #expect(locs.allSatisfy { $0.hasPrefix("https://devdrivecacheclean.com/") })

    // Every page but one: listing a URL that answers 404 is a contradiction,
    // and search engines read it as one.
    let htmlPages = files.keys.filter { $0.hasSuffix(".html") }
    #expect(locs.count == htmlPages.count - 1)
    #expect(!locs.contains { $0.contains("404") }, "the sitemap advertises the 404 page")
}

/// Section number, title and crumb are all derived from the markdown file.
@Test func aDocumentationPageIsDerivedFromItsSourceFile() throws {
    let data = try #require(try builtFiles()["user-guide/uninstall-view/index.html"],
                            "the uninstall-view guide page was not built")
    let html = String(decoding: data, as: UTF8.self)
    #expect(html.contains("§ 10"), "the section number is not derived from the file's position")
    #expect(html.contains("The Uninstall view"), "the title is not taken from the markdown's own heading")
    #expect(html.contains("Also in the app"), "the page no longer says it is also the app's help")
}

/// Output the builder no longer produces counts as drift.
@Test func aFileTheBuilderNoLongerProducesCountsAsDrift() throws {
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-stale-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }

    try writer().write(into: output)
    try #require(try writer().drift(against: output).isEmpty, "a fresh build must not drift from itself")

    let orphan = output.appending(path: "old-section/index.html")
    try FileManager.default.createDirectory(
        at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("a page nothing builds any more".utf8).write(to: orphan)

    let drift = try writer().drift(against: output)
    #expect(
        drift.contains { $0.hasPrefix("old-section/index.html") },
        "a file the builder does not produce was not reported: \(drift)")
}

/// The build removes what it no longer produces, rather than only reporting it.
@Test func rebuildingRemovesWhatItNoLongerProduces() throws {
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-prune-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }

    try writer().write(into: output)
    let orphan = output.appending(path: "old-section/index.html")
    try FileManager.default.createDirectory(
        at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: orphan)

    try writer().write(into: output)
    #expect(!FileManager.default.fileExists(atPath: orphan.path), "the stale page survived a rebuild")
    #expect(
        !FileManager.default.fileExists(atPath: orphan.deletingLastPathComponent().path),
        "the directory it emptied was left behind")
}

/// The prune must not reach into `assets/`, which never appears in the built file list.
@Test func pruningLeavesTheMirroredAssetsAlone() throws {
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-assets-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }

    try writer().write(into: output)
    try writer().write(into: output)

    let css = output.appending(path: "assets/css/site.css")
    #expect(FileManager.default.fileExists(atPath: css.path), "the stylesheet was pruned")
    let fonts = output.appending(path: "assets/fonts")
    #expect(FileManager.default.fileExists(atPath: fonts.path), "the fonts were pruned")
    #expect(try writer().drift(against: output).isEmpty, "assets were reported as stale")
}

/// `drift` must catch a changed asset, not only a changed page: the
/// stylesheet ships to all 32 pages and is the one file a wholesale mirror
/// copy makes easy to forget to compare.
@Test func driftCatchesAModifiedAsset() throws {
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-asset-drift-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }

    try writer().write(into: output)
    try #require(try writer().drift(against: output).isEmpty, "a fresh build must not drift from itself")

    let css = output.appending(path: "assets/css/site.css")
    try Data("/* tampered for the test */".utf8).write(to: css)

    let drift = try writer().drift(against: output)
    #expect(drift.contains("assets/css/site.css"),
            "a modified asset was not reported as drift: \(drift)")
}

/// A fragment named in `meta.json` that cannot be read is reported by name,
/// with the underlying reason — not folded into a generic "does not exist".
@Test func aMissingFragmentIsReportedByName() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "ddcc-missing-fragment-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    try FileManager.default.createDirectory(at: tmp.appending(path: "pages"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmp.appending(path: "templates"), withIntermediateDirectories: true)
    try Data("<html>{{body}}</html>".utf8).write(to: tmp.appending(path: "templates/shell.html"))
    let manifest = """
        {"pages":[{"slug":"","file":"missing.html","title":"t","description":"d","kind":"marketing","crumb":null}]}
        """
    try Data(manifest.utf8).write(to: tmp.appending(path: "meta.json"))

    let broken = SiteWriter(sourceRoot: tmp, helpRoot: repoRoot().appending(path: "Help"))
    #expect(throws: SiteError.self) {
        _ = try broken.files()
    }
}

/// `Shell.escape` is exercised directly: a title or description carrying a
/// reserved character must not break out of its attribute or tag.
@Test func theShellEscapesReservedCharactersInTitleAndDescription() throws {
    let shell = Shell(template: "<title>{{title}}</title><meta content=\"{{description}}\">{{canonical}}{{ogImage}}{{root}}{{head}}{{body}}{{nav}}{{crumb}}")
    let html = try shell.render(SitePage(
        slug: "", title: "A & B < C > D", description: "\"quoted\"", body: "b"))
    #expect(html.contains("<title>A &amp; B &lt; C &gt; D</title>"))
    #expect(html.contains("content=\"&quot;quoted&quot;\""))
}

/// Every non-file page must declare a `crumb`: it is the breadcrumb leaf, the
/// eyebrow label, and — via `renderFull` — the heading `llms-full.txt` gives
/// each section. A page with none would silently fall back to its `<title>`.
@Test func everyPageDeclaresACrumb() throws {
    let pages = try writer().allPages()
    try #require(pages.count >= 15, "only \(pages.count) pages; this test would prove little")
    for page in pages where !page.isFile {
        #expect(page.crumb != nil, "\(page.slug.isEmpty ? "/" : page.slug) has no crumb")
    }
}

// MARK: - The FAQ, and its structured data

private func claimBlocks(in html: String) -> [String] {
    innerTexts(html, "<div class=\"claim\">", "</div>")
}

private func visibleFAQ() throws -> (questions: [String], answers: [String]) {
    let page = try #require(try builtFiles()["faq/index.html"])
    let html = try #require(String(data: page, encoding: .utf8))
    // Scoped to `.claim` blocks rather than every `<p>` on the page: the page
    // has exactly one paragraph per question today, but nothing prevents an
    // unattributed `<p>` being added elsewhere in the fragment.
    let blocks = claimBlocks(in: html)
    let questions = blocks.map { innerTexts($0, "<h3>", "</h3>").first ?? "" }
    let answers = blocks.map { innerTexts($0, "<p>", "</p>").first ?? "" }
    return (questions, answers)
}

private func structuredFAQ() throws -> [(question: String, answer: String)] {
    let page = try #require(try builtFiles()["faq/index.html"])
    let html = try #require(String(data: page, encoding: .utf8))
    let open = try #require(html.range(of: "<script type=\"application/ld+json\">"))
    let close = try #require(html.range(of: "</script>", range: open.upperBound..<html.endIndex))
    let json = String(html[open.upperBound..<close.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Parsed, not string-matched: a block that is not valid JSON is invisible
    // to every consumer it exists for, and reading it as text would not notice.
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let root = try #require(object as? [String: Any])
    let entities = try #require(root["mainEntity"] as? [[String: Any]])
    return try entities.map { entity in
        let answer = try #require(entity["acceptedAnswer"] as? [String: Any])
        return (try #require(entity["name"] as? String),
                try #require(answer["text"] as? String))
    }
}

/// The FAQPage markup must state exactly what the page shows; a block that does not
/// match is discarded whole.
@Test func theStructuredDataSaysExactlyWhatThePageSays() throws {
    let visible = try visibleFAQ()
    let structured = try structuredFAQ()

    #expect(structured.count == visible.questions.count)
    for (index, pair) in zip(structured, zip(visible.questions, visible.answers)).enumerated() {
        let (marked, (question, answer)) = pair
        #expect(marked.question == question, "entry \(index): markup says \"\(marked.question)\", the page says \"\(question)\"")
        #expect(marked.answer == answer, "entry \(index): markup and page answers disagree for \"\(question)\"")
    }
}

/// Every entry is marked up, not a subset.
@Test func everyQuestionOnThePageIsMarkedUp() throws {
    let structured = try structuredFAQ()
    #expect(structured.count == FAQ.entries.count)
    #expect(!FAQ.entries.isEmpty)
}

// MARK: - Breadcrumbs and the application block

private func jsonLD(in html: String) throws -> [[String: Any]] {
    var out: [[String: Any]] = []
    var rest = Substring(html)
    while let open = rest.range(of: "<script type=\"application/ld+json\">"),
          let close = rest[open.upperBound...].range(of: "</script>") {
        let raw = rest[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Parsed, never string-matched: a block that is not valid JSON is
        // invisible to every consumer it exists for.
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        out.append(try #require(object as? [String: Any]))
        rest = rest[close.upperBound...]
    }
    return out
}

/// The trail in the markup must be the trail the page draws.
@Test func everyBreadcrumbNamesTheTrailThePageDraws() throws {
    var checked = 0
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        guard let crumbs = try jsonLD(in: html)
            .first(where: { $0["@type"] as? String == "BreadcrumbList" }) else { continue }

        let items = try #require(crumbs["itemListElement"] as? [[String: Any]])
        let names = try items.map { try #require($0["name"] as? String) }

        // Every name must appear in the rendered trail, in order.
        let nav = try #require(html.range(of: "aria-label=\"Breadcrumb\""))
        let close = try #require(html.range(of: "</nav>", range: nav.upperBound..<html.endIndex))
        // Unescaped before comparing: the trail on the page is HTML, so an
        // ampersand arrives as `&amp;`, while the JSON-LD correctly carries the
        // literal character. Both are right; only a naive comparison is wrong.
        let visible = String(html[nav.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        var cursor = visible.startIndex
        for name in names {
            let found = try #require(
                visible.range(of: name, range: cursor..<visible.endIndex),
                "\(path): breadcrumb names \"\(name)\", which the page does not draw")
            cursor = found.upperBound
        }

        // Positions are 1-based and consecutive, or a crawler discards the list.
        #expect(items.compactMap { $0["position"] as? Int } == Array(1...items.count))
        checked += 1
    }
    #expect(checked > 20, "expected a breadcrumb on nearly every page, saw \(checked)")
}

/// The front page has nowhere to point back to and the 404 does not know where
/// it is. Emitting a trail for either would describe a position neither has.
@Test func theFrontPageAndThe404CarryNoBreadcrumb() throws {
    for path in ["index.html", "404.html"] {
        let data = try #require(try builtFiles()[path])
        let html = try #require(String(data: data, encoding: .utf8))
        let types = try jsonLD(in: html).compactMap { $0["@type"] as? String }
        #expect(!types.contains("BreadcrumbList"), "\(path) claims a position in a trail")
    }
}

/// The download page carries SoftwareApplication, not HowTo, and asserts no version or
/// availability.
@Test func theDownloadPageDescribesTheApplicationAndNotAHowTo() throws {
    let data = try #require(try builtFiles()["download/index.html"])
    let html = try #require(String(data: data, encoding: .utf8))
    let blocks = try jsonLD(in: html)
    let types = blocks.compactMap { $0["@type"] as? String }

    #expect(types.contains("SoftwareApplication"))
    #expect(!types.contains("HowTo"))

    let app = try #require(blocks.first { $0["@type"] as? String == "SoftwareApplication" })
    let offers = try #require(app["offers"] as? [String: Any])
    #expect(offers["price"] as? String == "0")
    #expect(app["isAccessibleForFree"] as? Bool == true)

    // Nothing has shipped, so neither may be asserted yet.
    #expect(app["softwareVersion"] == nil)
    #expect(offers["availability"] == nil)
}

// MARK: - llms.txt, and the descriptions it shares with every meta tag

/// No description may end mid-word or mid-clause.
@Test func noDescriptionEndsMidWord() throws {
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        guard let open = html.range(of: "<meta name=\"description\" content=\""),
              let close = html.range(of: "\"", range: open.upperBound..<html.endIndex)
        else { continue }
        let text = String(html[open.upperBound..<close.lowerBound])
        #expect(!text.isEmpty, "\(path) has an empty description")
        let end = try #require(text.last)
        #expect(".!?…".contains(end),
                "\(path) description ends on \"\(text.suffix(40))\"")
    }
}

/// Generated from the same pages as the sitemap, so a page cannot be added to
/// the site and quietly left out of the index a model reads.
@Test func theLLMsIndexListsEveryPageWorthReading() throws {
    let data = try #require(try builtFiles()["llms.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    for page in try writer().allPages() {
        // The front page is the subject of the file, and the 404 is not a page
        // anyone should be sent to.
        guard !page.slug.isEmpty, !page.isFile else { continue }
        #expect(text.contains(page.canonical), "llms.txt omits \(page.slug)")
    }
    #expect(text.hasPrefix("# DevDriveCacheClean"))
    // The convention's one structural requirement: a blockquote summary.
    #expect(text.contains("\n> "))
}

// MARK: - llms-full.txt

/// It is generated from the rendered pages, so anything the shell was meant to
/// resolve must be resolved. A `{{crumb}}` reaching this file would mean a
/// model was handed template source instead of the page.
@Test func theFullExportCarriesNoTemplateSourceOrMarkup() throws {
    let data = try #require(try builtFiles()["llms-full.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(!text.contains("{{"), "llms-full.txt leaks an unresolved placeholder")
    #expect(!text.contains("</"), "llms-full.txt leaks a closing HTML tag")
    #expect(!text.contains("&amp;"), "llms-full.txt leaks an HTML entity")
    #expect(!text.contains("SYSTEM REQUIREMENTS"), "llms-full.txt carries the footer")
}

/// Every page's text, headed by the URL that a claim can be cited back to.
@Test func theFullExportContainsEveryPageAndItsSource() throws {
    let data = try #require(try builtFiles()["llms-full.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    for page in try writer().allPages() where !page.isFile {
        #expect(text.contains("Source: \(page.canonical)"), "llms-full.txt omits \(page.slug)")
    }
}

/// Each page shape exports only its own content: `<main>` for marketing,
/// `<article>` for the guide. `PlainText.markdown(from:)` throws rather than
/// falling back to the whole document when neither is present (see
/// `markdownThrowsWithoutAContentElement`), so the export cannot carry a
/// `<title>` or the masthead by construction.
@Test func bothPageShapesExportOnlyTheirContent() throws {
    let data = try #require(try builtFiles()["llms-full.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    // A marketing page and a guide page, each identified by a line only its
    // own content carries.
    #expect(text.contains("Tiers measure blast radius"))
    #expect(text.contains("Tiers describe the risk of removing an item"))
    // The guide's sidebar index lists every topic on every guide page.
    #expect(!text.contains("## TOPICS"), "llms-full.txt carries the guide sidebar")
    #expect(!text.contains("<title>"), "llms-full.txt leaks a <title> tag")
}

/// The one failure `bothPageShapesExportOnlyTheirContent` used to catch only
/// by proxy: a page with neither `<main>` nor `<article>` must fail the build,
/// not export the whole document.
@Test func markdownThrowsWithoutAContentElement() {
    #expect(throws: PlainTextError.self) {
        try PlainText.markdown(from: "<html><head><title>x</title></head><body>no content element</body></html>")
    }
}

/// Emphasis is meaning on these pages — the claim in a paragraph is what is
/// bolded — so it survives the conversion rather than being flattened away.
@Test func theFullExportKeepsStructureWorthKeeping() throws {
    let data = try #require(try builtFiles()["llms-full.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(text.contains("\n# "), "no page headings survived")
    #expect(text.contains("\n## "), "no section headings survived")
    #expect(text.contains("**"), "no emphasis survived")
    // A figure is emitted as one sentence joining its caption to its alt
    // text: "Figure — <caption>: <alt>." The two used to be orphan lines with
    // nothing relating them. Counted rather than merely present, so dropping a
    // figure fails here instead of passing on the fifteen that remain.
    let figures = captures(text, "\n(Figure — [^\n]+)")
    #expect(figures.count == 16, "expected 16 figures, found \(figures.count)")
    #expect(!text.contains("[Screenshot: "),
            "a figure was left in the old orphan-line form")
    // Tables carry the comparisons the argument rests on.
    #expect(text.contains(" — "), "table rows did not survive")
}

/// The footer is the trap: its column headings sit outside any body section,
/// so they must be `h2`. At `h3` they skip a level on the guide pages, whose
/// bodies carry no heading of their own.
@Test func noPageSkipsAHeadingLevel() throws {
    var checked = 0
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        let levels = captures(html, "<h([1-6])[ >]").compactMap(Int.init)
        var previous = 0
        for level in levels {
            #expect(previous == 0 || level <= previous + 1,
                    "\(path): h\(previous) is followed by h\(level)")
            previous = level
        }
        checked += 1
    }
    #expect(checked == 32)
}

/// Every page's first heading is its `h1`, and there is exactly one. The rail
/// labels on the guide pages precede the article in DOM order, so making them
/// headings would put an `h2` above the page's own title.
@Test func everyPageOpensWithExactlyOneH1() throws {
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        let levels = captures(html, "<h([1-6])[ >]").compactMap(Int.init)
        #expect(levels.filter { $0 == 1 }.count == 1, "\(path): expected exactly one h1")
        #expect(levels.first == 1, "\(path): first heading is h\(levels.first ?? 0), not h1")
    }
}

/// Below-the-fold screenshots must defer, and the one image likely to be the
/// largest contentful paint must not. A page that lazy-loads its own LCP image
/// delays the metric it is being measured on.
@Test func screenshotsDeferExceptTheLikelyLCP() throws {
    var eager = 0, lazy = 0
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        for tag in captures(html, "(<img [^>]*assets/screenshots/[^>]*>)") {
            let isEager = tag.contains("fetchpriority=\"high\"")
            let isLazy = tag.contains("loading=\"lazy\"")
            #expect(isEager != isLazy, "\(path): a screenshot is both or neither eager and lazy")
            #expect(tag.contains("decoding=\"async\""), "\(path): screenshot lacks decoding")
            if isEager { eager += 1 } else { lazy += 1 }
        }
    }
    #expect(eager == 4)
    #expect(lazy == 12)
}

/// An AVIF sibling on disk that no page references is weight nobody is served.
@Test func everyGeneratedAVIFIsReferencedByAPage() throws {
    let dir = repoRoot().appending(path: "Site/assets/screenshots")
    let avif = try FileManager.default.contentsOfDirectory(atPath: dir.path())
        .filter { $0.hasSuffix(".avif") }
    #expect(!avif.isEmpty)

    let pages = try builtFiles().filter { $0.key.hasSuffix(".html") }
        .compactMap { String(data: $0.value, encoding: .utf8) }
        .joined()
    for file in avif {
        #expect(pages.contains(file), "\(file) is generated but no page references it")
    }
}

/// The privacy page tells the reader that nothing is written to their device
/// and invites them to check the storage inspector. A service worker or any
/// storage write would make that sentence false, so the claim is enforced here
/// rather than trusted.
@Test func noPageWritesToTheVisitorsDevice() throws {
    let forbidden = ["serviceWorker", "navigator.storage", "localStorage",
                     "sessionStorage", "indexedDB", "caches.open"]
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        for token in forbidden {
            #expect(!html.contains(token), "\(path) references \(token)")
        }
    }
}

/// Prefetch fetches a document; prerender executes it, which would fire the
/// analytics script for a page nobody opened. Only the first is permitted, and
/// only at an eagerness that waits for the visitor to show intent.
@Test func speculationRulesPrefetchOnHoverAndNeverPrerender() throws {
    var seen = 0
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        guard let block = innerTexts(html, "<script type=\"speculationrules\">", "</script>").first
        else { continue }
        #expect(!block.contains("prerender"), "\(path) speculation rules use prerender")
        #expect(block.contains("\"prefetch\""), "\(path) speculation rules omit prefetch")
        #expect(block.contains("\"eagerness\": \"moderate\""),
                "\(path) does not wait for visitor intent")

        let json = try #require(block.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: json)   // must be valid JSON to be honoured
        seen += 1
    }
    #expect(seen == 32)
}

/// RFC 9116 requires an `Expires` field and gives it no default, so the date
/// rots silently into a file every scanner reports as expired. Failing thirty
/// days ahead turns that into something a build tells you about.
@Test func theSecurityContactHasNotExpired() throws {
    let files = try builtFiles()
    let data = try #require(files[".well-known/security.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("Expires:") })
    let stamp = line.dropFirst("Expires:".count).trimmingCharacters(in: .whitespaces)
    let expires = try #require(ISO8601DateFormatter().date(from: stamp))

    let thirtyDays = Date().addingTimeInterval(30 * 24 * 60 * 60)
    #expect(expires > thirtyDays,
            "security.txt expires \(stamp); update Site.securityContactExpires")

    #expect(text.contains("Contact: mailto:\(Site.supportEmail)"))
    #expect(text.contains("Policy: \(Site.origin)/security/"))
}

/// The developer is a single entity the application's claims hang off. Two
/// inline copies would be two people as far as a crawler is concerned, which
/// is why the blocks reference one `@id`.
@Test func theApplicationIsAttributedToOneNamedDeveloper() throws {
    let files = try builtFiles()
    let frontData = try #require(files["index.html"])
    let front = try #require(String(data: frontData, encoding: .utf8))
    let blocks = try jsonLD(in: front)

    let person = try #require(blocks.first { $0["@type"] as? String == "Person" })
    #expect(person["name"] as? String == Site.developer)
    #expect(person["@id"] as? String == "\(Site.origin)/#developer")

    let app = try #require(blocks.first { $0["@type"] as? String == "SoftwareApplication" })
    let author = try #require(app["author"] as? [String: Any])
    #expect(author["@id"] as? String == person["@id"] as? String)

    // The licence is a URL, not a name: SUL-1.0 has no SPDX identifier for a
    // crawler to resolve, and calling it "open source" would be wrong.
    #expect(app["license"] as? String == "\(Site.origin)/licence/")

    // Nothing may claim a rating or a released version that does not exist.
    #expect(app["aggregateRating"] == nil)
    #expect(app["review"] == nil)
    #expect(app["softwareVersion"] == nil)
}

/// The colophon renders the same constant the `Person` block does, so the
/// visible name and the machine-readable one cannot drift apart.
@Test func theFooterNamesTheSameDeveloperTheSchemaDoes() throws {
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))
        #expect(html.contains(Site.developer), "\(path) does not name the developer")
    }
}

/// Four ways the conversion can produce garbage: currency glyphs closing up,
/// a card's bold label fusing to its sentence, pagination chrome, and a figure
/// split from its alt text.
@Test func theFullExportCarriesNoRenderingArtefacts() throws {
    let files = try builtFiles()
    let data = try #require(files["llms-full.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(!text.contains("€0,00£0.00"), "currency glyphs are closing up again")
    #expect(text.contains("Zero, in every currency"), "the readout's aria-label was dropped")

    #expect(captures(text, "(\\*\\*[^*\n]+\\*\\*[A-Za-z])").isEmpty,
            "a bold label is fused to the sentence after it")
    #expect(!text.contains("\nPREVIOUS"), "pagination chrome is in the export")
    #expect(!text.contains("\nNEXT"), "pagination chrome is in the export")
    #expect(!text.contains("\nFIG. "), "a figure is still split across lines")
    #expect(text.contains("\nFigure — "), "figures are not being joined to their alt text")
}

/// The front matter answers what DDCC is, who makes it, what it costs and what
/// its licence permits, without a consumer reading any body text. `page_count`
/// has to match what the file actually carries or it is worse than absent.
@Test func theFullExportDeclaresItselfInFrontMatter() throws {
    let files = try builtFiles()
    let data = try #require(files["llms-full.txt"])
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(text.hasPrefix("---\n"), "front matter must open the file")
    for field in ["title:", "alternate_names:", "source_domain:", "canonical_index:",
                  "page_count:", "license_of_software:", "price:", "platform:",
                  "maker:", "repository:"] {
        #expect(text.contains("\n\(field)"), "front matter omits \(field)")
    }
    #expect(text.contains("maker: \(Site.developer)"))
    #expect(text.contains("NOT OSI-approved open source"),
            "the licence line must state the distinction, not just the name")

    // No build clock: the site is committed and compared byte for byte, so a
    // timestamp would make a clean checkout fail its own drift check.
    #expect(!text.contains("generated:"))

    let declared = try #require(captures(text, "page_count: (\\d+)").first.flatMap(Int.init))
    let sections = captures(text, "\nSource: (https://[^\n]+)").count
    #expect(declared == sections,
            "front matter claims \(declared) pages; the file carries \(sections)")
}

/// One definition, used by the schema and the export both. Two wordings would
/// be two answers to "what is DDCC", and nothing would say which is current.
@Test func theCanonicalDefinitionIsStatedIdenticallyEverywhere() throws {
    let files = try builtFiles()
    let fullData = try #require(files["llms-full.txt"])
    let full = try #require(String(data: fullData, encoding: .utf8))
    #expect(full.contains(Site.canonicalDefinition))

    let frontData = try #require(files["index.html"])
    let front = try #require(String(data: frontData, encoding: .utf8))
    let app = try #require(try jsonLD(in: front)
        .first { $0["@type"] as? String == "SoftwareApplication" })
    #expect(app["description"] as? String == Site.canonicalDefinition)

    // The four facts it exists to state. Counting sentences would be brittle:
    // "Sustainable Use License 1.0" carries a full stop of its own.
    for fact in ["free macOS disk-cleanup application",
                 "It is made by \(Site.developer)",
                 "macOS 15 or later",
                 "not an OSI-approved open-source licence"] {
        #expect(Site.canonicalDefinition.contains(fact), "the definition drops: \(fact)")
    }
}

/// Both limits are where a search result truncates, not style preferences: a
/// title is rendered to about 60 characters and a description to about 160,
/// and past either the snippet stops mid-clause. No lower bound — the licence
/// and guide titles are deliberately short.
@Test func noTitleOrDescriptionWillBeTruncatedInAResult() throws {
    var checked = 0
    for (path, data) in try builtFiles() where path.hasSuffix(".html") {
        let html = try #require(String(data: data, encoding: .utf8))

        let title = try #require(captures(html, "<title>([^<]*)</title>").first)
        #expect(title.count <= 60, "\(path): title is \(title.count) characters")

        let description = try #require(
            captures(html, "<meta name=\"description\" content=\"([^\"]*)\"").first)
        #expect(description.count <= 160,
                "\(path): description is \(description.count) characters")
        checked += 1
    }
    #expect(checked == 32)
}

/// The set of paths DDCC shows but never removes is closed and small, so the
/// reference page lists it in full rather than sampling it. Derived from the
/// scan profiles, so the page cannot claim a refusal the app does not make —
/// nor omit one it does.
@Test func theRemovabilityPageListsEveryPathTheAppRefusesToRemove() throws {
    let refused = ScanProfile.all
        .flatMap(\.patterns)
        .filter { $0.removability == .requiresPrivileges }
        .compactMap { pattern -> String? in
            if case .absolutePath(let path) = pattern.kind { return path }
            return nil
        }
    #expect(refused.count >= 3, "the profiles refuse \(refused.count) fixed paths")

    let files = try builtFiles()
    let data = try #require(files["user-guide/reference-removability/index.html"])
    let html = try #require(String(data: data, encoding: .utf8))

    for path in refused {
        #expect(html.contains(path), "the page omits \(path), which the app refuses")
    }
}

/// Retaking a screenshot without regenerating its derivatives is invisible:
/// the page still renders, serving an AVIF of the old capture beside prose
/// about the new one. The manifest is written only by
/// `Scripts/make-screenshots.sh`, so a master whose hash has moved is a master
/// whose derivatives were never rebuilt.
@Test func everyScreenshotMasterMatchesItsGeneratedDerivatives() throws {
    let root = repoRoot()
    let masters = root.appending(path: "Site/screenshots")
    let served = root.appending(path: "Site/assets/screenshots")
    let fm = FileManager.default

    let manifestText = try String(contentsOf: masters.appending(path: "manifest.txt"), encoding: .utf8)
    var recorded: [String: String] = [:]
    for line in manifestText.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2 { recorded[String(parts[parts.count - 1])] = String(parts[0]) }
    }

    let onDisk = try fm.contentsOfDirectory(atPath: masters.path())
        .filter { $0.hasSuffix("@2x.png") }.sorted()
    #expect(onDisk.count == 11)
    #expect(Set(onDisk) == Set(recorded.keys),
            "the manifest and Site/screenshots disagree about which masters exist")

    for file in onDisk {
        let data = try Data(contentsOf: masters.appending(path: file))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == recorded[file],
                "\(file) has changed since the derivatives were generated; run Scripts/make-screenshots.sh")

        // Every master owes five served files: AVIF and WebP at both densities,
        // plus the PNG the `<img>` falls back to.
        let base = String(file.dropLast("@2x.png".count))
        for name in ["\(base).avif", "\(base)@2x.avif",
                     "\(base).webp", "\(base)@2x.webp", "\(base)@2x.png"] {
            #expect(fm.fileExists(atPath: served.appending(path: name).path()),
                    "\(name) is missing; run Scripts/make-screenshots.sh")
        }
    }
}

/// A generated file no page references is weight in the repository and in the
/// clone, serving nobody.
@Test func everyServedScreenshotIsReferencedByAPage() throws {
    let served = repoRoot().appending(path: "Site/assets/screenshots")
    let files = try FileManager.default.contentsOfDirectory(atPath: served.path()).sorted()
    #expect(files.count == 55)

    let pages = try builtFiles().filter { $0.key.hasSuffix(".html") }
        .compactMap { String(data: $0.value, encoding: .utf8) }.joined()
    for file in files {
        #expect(pages.contains(file), "\(file) is generated but no page references it")
    }
}

/// The download page publishes this app's own size, and `Scripts/make-dmg.sh`
/// refuses to build a release whose artifact exceeds it. That check finds the
/// claim by pattern, so a reworded line disables it — the script fails closed
/// rather than passing silently, but only at release time, which is late.
///
/// This asserts the shape the script greps for, so a rewrite is caught by the
/// suite instead. If the wording should change, change it in both places.
@Test func theDownloadPagePublishesAFootprintTheReleaseScriptCanRead() throws {
    let page = try String(
        contentsOf: repoRoot().appending(path: "Site/pages/download.html"), encoding: .utf8)

    // The same expression as make-dmg.sh's grep -oE.
    let pattern = /([0-9.]+) MB download, ([0-9.]+) MB installed/
    let matches = page.matches(of: pattern)
    #expect(matches.count == 1, "expected exactly one footprint claim, found \(matches.count)")

    guard let match = matches.first else { return }
    let download = Double(match.output.1) ?? 0
    let installed = Double(match.output.2) ?? 0
    // Sanity, not a ceiling: the ceiling is checked against the real artifact
    // at release. This only catches a claim that is obviously not a size.
    #expect(download > 0 && download < 1000)
    #expect(installed > download, "an app cannot install smaller than its download")
}
