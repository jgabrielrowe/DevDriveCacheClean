import Foundation
import HelpBookGen

/// Turns Help/*.md into web documentation, rendered by the same `MarkdownSubset` as
/// the app's Help Book.
public enum DocumentationPages {

    /// Order drives the section numbers and the previous/next links. Reference pages
    /// carry R-numbers.
    public static let topics = [
        "what-ddcc-does", "first-scan", "reading-results", "honest-number",
        "choosing-what-to-remove", "unlocking-tiers", "deleting-cache-results",
        "trash-not-delete", "files-view", "uninstall-view", "full-disk-access",
        "privacy",
    ]
    public static let reference = [
        "reference-tiers", "reference-removability",
        "reference-categories", "reference-files",
    ]

    struct Source {
        let slug: String
        let number: String
        let isReference: Bool
        /// Rendered once, here, rather than re-rendered every time a title or
        /// a body is needed — `indexHTML`, `contentsPage` and `pageNav` each
        /// read a title for every source.
        let html: String
        let title: String
    }

    public static func pages(helpRoot: URL) throws -> [SitePage] {
        var sources: [Source] = []
        for (i, slug) in topics.enumerated() {
            let html = try MarkdownSubset.html(from: try read(helpRoot, "pages", slug))
            sources.append(Source(slug: slug, number: String(format: "%02d", i + 1),
                                  isReference: false, html: html, title: firstHeading(html) ?? slug))
        }
        for (i, slug) in reference.enumerated() {
            let html = try MarkdownSubset.html(from: try read(helpRoot, "generated", slug))
            sources.append(Source(slug: slug, number: "R\(i + 1)",
                                  isReference: true, html: html, title: firstHeading(html) ?? slug))
        }

        let index = indexHTML(sources)
        return try [contentsPage(sources)] + sources.enumerated().map { position, source in
            try page(source, at: position, in: sources, index: index)
        }
    }

    private static func read(_ root: URL, _ folder: String, _ slug: String) throws -> String {
        try String(contentsOf: root.appending(path: "\(folder)/\(slug).md"), encoding: .utf8)
    }

    // MARK: - One page

    private static func page(_ source: Source, at position: Int,
                             in all: [Source], index: String) throws -> SitePage {
        let rendered = source.html
        let title = source.title

        var article = rendered
        // The title moves into the page furniture; the body must not repeat it.
        article = replaceFirst(article, pattern: #"<h1>.*?</h1>\n?"#, with: "")

        // Mark the opening paragraph as the standfirst.
        article = replaceFirst(article, pattern: #"<p>"#, with: #"<p class="standfirst">"#)

        // Cross-references between guide topics are authored as the Help
        // Book's own sibling filenames (`slug.html`); rewritten to this
        // section's directory-per-page links so they resolve on the website.
        for other in all {
            article = article.replacingOccurrences(
                of: "href=\"\(other.slug).html\"", with: "href=\"../\(other.slug)/\"")
        }

        // Subheads are numbered from the file's position in the section.
        var subheads: [String] = []
        while let range = article.range(of: #"<h3>(.*?)</h3>"#, options: .regularExpression) {
            let heading = String(article[range])
            let text = heading
                .replacingOccurrences(of: "<h3>", with: "")
                .replacingOccurrences(of: "</h3>", with: "")
            subheads.append(text)
            let anchor = slugify(text)
            article.replaceSubrange(range, with:
                "<h2 id=\"\(anchor)\" data-n=\"\(source.number).\(subheads.count)\">\(text)</h2>")
        }

        let body = """
        <div class="shell">

          <aside class="index">
        \(index)  </aside>

          <article>
            <nav class="crumb" aria-label="Breadcrumb"><span class="sec">§ \(source.number)</span>\
        <a href="{{root}}">DDCC</a><span class="sep" aria-hidden="true">/</span>\
        <a href="{{root}}\(Site.guidePath)">User Guide</a><span class="sep" aria-hidden="true">/</span>\
        <span aria-current="page">\(title)</span></nav>
            <h1>\(title)</h1>
        \(indent(article, by: 4))
        \(pageNav(at: position, in: all))
          </article>

          <aside class="contents">
        \(contentsHTML(subheads, source: source))  </aside>

        </div>
        """

        return SitePage(
            slug: "\(Site.guidePath)\(source.slug)/",
            title: "\(title) — DDCC User Guide",
            description: description(from: rendered, fallback: title),
            kind: .documentation,
            body: body,
            // Not rendered — the body draws its own trail. `StructuredData.breadcrumb`
            // needs the leaf.
            crumb: title)
    }

    /// The section's own front page, at the guide path the masthead links to.
    private static func contentsPage(_ sources: [Source]) -> SitePage {
        func list(_ items: [Source]) -> String {
            "        <ol class=\"guide-list\">\n" + items.map { s in
                "          <li><a href=\"\(s.slug)/\"><span class=\"num\">\(s.number)</span>"
                + "<span>\(s.title)</span></a></li>\n"
            }.joined() + "        </ol>"
        }
        let topics = sources.filter { !$0.isReference }
        let reference = sources.filter(\.isReference)

        return SitePage(
            slug: Site.guidePath,
            title: "User Guide — DDCC",
            description: """
                Every page of DDCC's built-in Help, published in full: how a scan works, \
                how totals are reported, and reference tables for categories, tiers, and \
                refusals.
                """,
            kind: .marketing,
            body: """
                <main>
                <div class="wrap">
                  <div class="hero">
                    {{crumb}}
                    <h1>User Guide</h1>
                  </div>
                  <div class="two-col guide-contents">
                    <div>
                      <h2>Topics</h2>
                \(list(topics))
                    </div>
                    <div>
                      <h2>Reference</h2>
                \(list(reference))
                    </div>
                  </div>
                </div>
                </main>
                """,
            crumb: "User Guide")
    }

    // MARK: - Furniture

    private static func indexHTML(_ sources: [Source]) -> String {
        func list(_ items: [Source]) -> String {
            "    <ol>\n" + items.map { s in
                "      <li><a href=\"../\(s.slug)/\"><span class=\"num\">\(s.number)</span>"
                + "<span>\(s.title)</span></a></li>\n"
            }.joined() + "    </ol>\n"
        }
        return "    <p class=\"rail-label\">TOPICS</p>\n" + list(sources.filter { !$0.isReference })
            + "    <p class=\"rail-label\">REFERENCE</p>\n" + list(sources.filter(\.isReference))
    }

    private static func contentsHTML(_ subheads: [String], source: Source) -> String {
        var out = ""
        if !subheads.isEmpty {
            out += "    <p class=\"rail-label\">ON THIS PAGE</p>\n    <ol>\n"
            out += subheads.map { "      <li><a href=\"#\(slugify($0))\">\($0)</a></li>\n" }.joined()
            out += "    </ol>\n"
        }
        out += """
            <div class="meta">
              Also in the app<br>Help › DDCC Help
            </div>

        """
        return out
    }

    private static func pageNav(at position: Int, in all: [Source]) -> String {
        var out = "    <div class=\"pagenav\">\n"
        if position > 0 {
            let p = all[position - 1]
            out += "      <a href=\"../\(p.slug)/\"><span>PREVIOUS</span>"
                + "<b>\(p.number) · \(p.title)</b></a>\n"
        } else {
            out += "      <span></span>\n"
        }
        if position + 1 < all.count {
            let n = all[position + 1]
            out += "      <a class=\"next\" href=\"../\(n.slug)/\"><span>NEXT</span>"
                + "<b>\(n.number) · \(n.title)</b></a>\n"
        }
        return out + "    </div>\n"
    }

    // MARK: - Text

    private static func firstHeading(_ html: String) -> String? {
        guard let r = html.range(of: #"<h1>(.*?)</h1>"#, options: .regularExpression) else { return nil }
        return String(html[r]).replacingOccurrences(of: "<h1>", with: "")
            .replacingOccurrences(of: "</h1>", with: "")
    }

    /// Meta description: the page's first paragraph, stripped of markup and trimmed.
    private static func description(from html: String, fallback: String) -> String {
        guard let r = html.range(of: #"<p>(.|\n)*?</p>"#, options: .regularExpression) else {
            return fallback
        }
        let text = String(html[r])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return trimmed(text, to: 155)
    }

    /// Cuts to `limit` at the last sentence that fits, or the last whole word plus an
    /// ellipsis.
    private static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let window = String(text.prefix(limit))

        if let stop = window.range(of: ". ", options: .backwards) {
            return String(window[window.startIndex..<stop.lowerBound]) + "."
        }
        guard let space = window.range(of: " ", options: .backwards) else {
            return window
        }
        return String(window[window.startIndex..<space.lowerBound]) + "…"
    }

    private static func slugify(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func replaceFirst(_ text: String, pattern: String, with replacement: String) -> String {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: r, with: replacement)
    }
}
