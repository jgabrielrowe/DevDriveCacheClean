import Foundation

/// Site-wide constants shared by the generator and the shell.
public enum Site {

    public static let origin = "https://devdrivecacheclean.com"

    public static let supportEmail = "support@devdrivecacheclean.com"

    /// What DDCC is, in four independently quotable sentences. Used by both
    /// `SoftwareApplication.description` and `llms-full.txt`, so the two cannot
    /// disagree about what the product is.
    public static let canonicalDefinition = """
        DevDriveCacheClean (DDCC) is a free macOS disk-cleanup application for developers. \
        It is made by \(developer), distributed as a single free download with no paid \
        tier. It requires macOS 15 or later on Apple silicon or Intel, has no account and \
        makes no network connections. It is source-available under the Sustainable Use \
        License 1.0, which is not an OSI-approved open-source licence.
        """

    /// When the published `security.txt` stops being valid. RFC 9116 requires
    /// the field and gives it no default, so an unattended date silently rots
    /// into a file every scanner reports as expired. A test fails once this is
    /// within thirty days, which turns that rot into a red build.
    public static let securityContactExpires = "2027-12-31T00:00:00Z"

    /// The developer, named once. The footer colophon renders this; the
    /// `Person` block in `StructuredData` gives an engine the same fact in a
    /// form it can attach the site's claims to.
    public static let developer = "Jonathan Rowe"

    /// Profiles that are demonstrably the same entity as the developer above.
    /// `sameAs` is only worth stating where a reader could verify the link.
    public static let developerProfiles = ["https://github.com/jgabrielrowe"]

    /// The one-off donation link. Declared here so the support page and the
    /// application's `sameAs` cannot drift apart.
    public static let donationURL = "https://ko-fi.com/RareBit"

    public static let repository = "https://github.com/jgabrielrowe/drive-clean"

    /// Slug prefix for the user guide. Page slugs, the masthead entry and the current-
    /// page rule are all built from it.
    public static let guidePath = "user-guide/"

    /// The masthead, in order.
    public static let nav: [(title: String, path: String)] = [
        ("Caches", "caches/"),
        ("Uninstall", "uninstall/"),
        ("Files", "large-files/"),
        ("The Number", "the-honest-number/"),
        ("User Guide", Site.guidePath),
        ("FAQ", "faq/"),
        ("Download", "download/"),
    ]

    /// The footer's link groups, in order. Declared once so the footer and
    /// `LLMsIndex` read the same account of the site's parts, rather than two
    /// hand-maintained lists that can disagree. Deliberately separate from
    /// `nav`: the masthead is a curated subset, not the same list.
    public static let footerGroups: [(heading: String, links: [(title: String, path: String)])] = [
        ("The app", [
            ("Download", "download/"),
            ("Caches", "caches/"),
            ("Uninstall", "uninstall/"),
            ("Large files", "large-files/"),
        ]),
        ("Why DDCC", [
            ("The honest number", "the-honest-number/"),
            ("How it decides", "how-it-decides/"),
            ("User Guide", Site.guidePath),
            ("FAQ", "faq/"),
            ("Support the project", "support/"),
        ]),
        ("Legal", [
            ("Licence", "licence/"),
            ("Terms", "terms/"),
            ("Privacy", "privacy/"),
            ("Security", "security/"),
            ("Contact", "contact/"),
        ]),
    ]
}

/// One page to emit.
public struct SitePage: Sendable {

    /// Documentation renders a three-column layout; marketing renders full-width
    /// sections.
    public enum Kind: String, Sendable, Codable {
        case marketing
        case documentation
    }

    /// Directory-style path with a trailing slash, or "" for the front page.
    /// Emitted as `<slug>/index.html` so URLs carry no extension.
    public let slug: String
    public let title: String
    public let description: String
    public let kind: Kind
    /// Extra `<head>` content — a page's own `<style>`, or its JSON-LD.
    public let head: String
    /// The body, already HTML: `<main>` and its sections.
    public let body: String
    /// Breadcrumb leaf, also used as the eyebrow label. `nil` for a page with neither.
    public let crumb: String?

    public init(slug: String, title: String, description: String,
                kind: Kind = .marketing, head: String = "", body: String,
                crumb: String? = nil) {
        self.slug = slug
        self.title = title
        self.description = description
        self.kind = kind
        self.head = head
        self.body = body
        self.crumb = crumb
    }

    /// A slug naming a file is emitted as that file. Only 404.html: GitHub Pages serves
    /// it for a request at any depth.
    var isFile: Bool { slug.hasSuffix(".html") }

    /// Where the file goes, relative to the output directory.
    public var outputPath: String {
        if isFile { return slug }
        return slug.isEmpty ? "index.html" : "\(slug)index.html"
    }

    public var canonical: String {
        slug.isEmpty ? "\(Site.origin)/" : "\(Site.origin)/\(slug)"
    }

    /// Excludes the 404, which must not appear in a sitemap.
    public var belongsInSitemap: Bool { !isFile }

    /// Relative prefix to the site root, so the built site opens from disk.
    public var rootPrefix: String {
        // Served for any request path, so its links must be site-absolute.
        if isFile { return "/" }
        let depth = slug.split(separator: "/").count
        return depth == 0 ? "" : String(repeating: "../", count: depth)
    }
}

/// The per-page metadata that does not belong in a body fragment.
public struct PageManifestEntry: Codable, Sendable {
    public let slug: String
    public let file: String
    public let title: String
    public let description: String
    public let kind: SitePage.Kind
    public let crumb: String?
}

public struct PageManifest: Codable, Sendable {
    public let pages: [PageManifestEntry]

    public static func load(from url: URL) throws -> PageManifest {
        try JSONDecoder().decode(PageManifest.self, from: Data(contentsOf: url))
    }
}
