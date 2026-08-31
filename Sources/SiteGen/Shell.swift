import Foundation

public enum ShellError: Error, Equatable {
    /// A `{{name}}` survived rendering.
    case unresolvedPlaceholder(page: String, name: String)
    case missingMetadata(page: String, field: String)
}

/// Wraps a body fragment in the site's one shell. `{{name}}` substitution only; title,
/// description and canonical come from the manifest.
public struct Shell: Sendable {

    private let template: String

    public init(template: String) {
        self.template = template
    }

    public init(contentsOf url: URL) throws {
        self.init(template: try String(contentsOf: url, encoding: .utf8))
    }

    public func render(_ page: SitePage) throws -> String {
        guard !page.title.isEmpty else {
            throw ShellError.missingMetadata(page: page.outputPath, field: "title")
        }
        guard !page.description.isEmpty else {
            throw ShellError.missingMetadata(page: page.outputPath, field: "description")
        }

        let root = page.rootPrefix
        let values: [String: String] = [
            "title": escape(page.title),
            "description": escape(page.description),
            "canonical": page.canonical,
            "ogImage": "\(Site.origin)/assets/img/og-default.png",
            "root": root,
            "head": try headHTML(page),
            "body": page.body,
            "nav": navHTML(current: page.slug, root: root),
            "crumb": crumbHTML(page),
            "email": Site.supportEmail,
            "repo": Site.repository,
            "developer": escape(Site.developer),
            "footerApp": footerColumnHTML(heading: "The app", root: root),
            "footerWhy": footerColumnHTML(heading: "Why DDCC", root: root),
            "footerLegal": footerLegalHTML(root: root),
        ]

        // body and head first: they carry placeholders of their own, and dictionary
        // order is not stable.
        var out = template
        for key in ["body", "head"] {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: values[key] ?? "")
        }
        for (key, value) in values where key != "body" && key != "head" {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        if let leftover = out.range(of: #"\{\{[^}\s]+\}\}"#, options: .regularExpression) {
            throw ShellError.unresolvedPlaceholder(
                page: page.outputPath, name: String(out[leftover]))
        }
        return out
    }

    /// Marks the current entry. Any page under the guide path marks User Guide.
    private func navHTML(current: String, root: String) -> String {
        Site.nav.enumerated().map { index, item in
            let isCurrent = current == item.path
                || (item.path == Site.guidePath && current.hasPrefix(Site.guidePath))
            let mark = isCurrent ? " aria-current=\"page\"" : ""
            // --i drives the narrow menu's stagger, so the delays track the entry
            // count.
            return "      <a href=\"\(root)\(item.path)\" style=\"--i:\(index)\"\(mark)>\(item.title)</a>\n"
        }.joined()
    }

    /// The page's own head content, plus its JSON-LD.
    private func headHTML(_ page: SitePage) throws -> String {
        var parts: [String] = []
        if !page.head.isEmpty { parts.append(page.head) }
        if let crumbs = StructuredData.breadcrumb(for: page) {
            parts.append(try StructuredData.script(crumbs))
        }
        // `WebSite` and `Person` are read only at the site root.
        if page.slug.isEmpty {
            parts.append(try StructuredData.script(StructuredData.website))
            parts.append(try StructuredData.script(StructuredData.developer))
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n") + "\n"
    }

    private func crumbHTML(_ page: SitePage) -> String {
        guard let label = page.crumb else { return "" }
        let leaf = escape(label)
        guard !page.slug.isEmpty, !page.isFile else {
            return "<div class=\"eyebrow\">\(leaf)</div>"
        }
        return "<nav class=\"eyebrow crumbs\" aria-label=\"Breadcrumb\">"
            + "<a href=\"\(page.rootPrefix)\">DDCC</a>"
            + "<span class=\"sep\" aria-hidden=\"true\">/</span>"
            + "<span aria-current=\"page\">\(leaf)</span></nav>"
    }

    /// One footer column: a heading and its link list, from `Site.footerGroups`.
    private func footerColumnHTML(heading: String, root: String) -> String {
        guard let group = Site.footerGroups.first(where: { $0.heading == heading }) else { return "" }
        let items = group.links
            .map { "<li><a href=\"\(root)\($0.path)\">\($0.title)</a></li>" }
            .joined()
        return "<h2>\(heading.uppercased())</h2>\n        <ul>\(items)</ul>"
    }

    /// The colophon's inline legal links, from `Site.footerGroups`.
    private func footerLegalHTML(root: String) -> String {
        guard let group = Site.footerGroups.first(where: { $0.heading == "Legal" }) else { return "" }
        let links = group.links
            .map { "<a href=\"\(root)\($0.path)\">\($0.title)</a>" }
            .joined(separator: "\n        ")
        // Wrapped as one child so the colophon breaks between the notice and the
        // links rather than through the middle of them.
        return "<div class=\"colophon-legal\">\n        \(links)\n      </div>"
    }

    private func escape(_ text: String) -> String {
        escapeHTML(text)
    }
}
