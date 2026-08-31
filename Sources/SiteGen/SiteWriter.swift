import Foundation

public enum SiteError: Error, CustomStringConvertible {
    case missingFragment(String, underlying: String)
    case duplicateSlug(String)
    case missingRendering(String)
    case drift([String])

    public var description: String {
        switch self {
        case .missingFragment(let name, let underlying):
            return "Site/pages/\(name) is named in meta.json but does not exist: \(underlying)"
        case .duplicateSlug(let slug):
            return "two pages both claim the slug \"\(slug)\""
        case .missingRendering(let slug):
            return "no rendered HTML for \"\(slug)\"; llms-full.txt cannot export it"
        case .drift(let paths):
            let list = paths.prefix(12).map { "  \($0)" }.joined(separator: "\n")
            let more = paths.count > 12 ? "\n  … and \(paths.count - 12) more" : ""
            return "committed site differs from the builder:\n\(list)\(more)"
        }
    }
}

/// Builds the whole site into a directory. Output is committed and served from docs/,
/// so the build must be byte-reproducible: no timestamps, no filesystem-dependent
/// ordering.
public struct SiteWriter {

    let sourceRoot: URL     // Site/
    let helpRoot: URL       // Help/
    let licenceURL: URL     // LICENSE.md

    public init(sourceRoot: URL, helpRoot: URL, licenceURL: URL? = nil) {
        self.sourceRoot = sourceRoot
        self.helpRoot = helpRoot
        // Defaults to the repository root's LICENSE.md. Injectable for tests.
        self.licenceURL = licenceURL
            ?? sourceRoot.deletingLastPathComponent().appending(path: "LICENSE.md")
    }

    /// Every file the site consists of, as path → bytes. Produced in memory so
    /// `--check` can compare without writing anything.
    public func files() throws -> [String: Data] {
        let shell = try Shell(contentsOf: sourceRoot.appending(path: "templates/shell.html"))
        let pages = try allPages()
        var out: [String: Data] = [:]

        var rendered: [String: String] = [:]
        for page in pages {
            let html = try shell.render(page)
            out[page.outputPath] = Data(html.utf8)
            rendered[page.slug] = html
        }

        out["sitemap.xml"] = Data(sitemap(for: pages).utf8)
        out["llms.txt"] = Data(LLMsIndex.render(pages: pages).utf8)
        out["llms-full.txt"] = Data(try LLMsIndex.renderFull(pages: pages, rendered: rendered).utf8)
        out["robots.txt"] = Data("""
            User-agent: *
            Allow: /

            Sitemap: \(Site.origin)/sitemap.xml

            # Plain-text renderings of this site, for agents that would rather
            # not parse the markup. llms.txt is the index; llms-full.txt is
            # every page in full.
            # \(Site.origin)/llms.txt
            # \(Site.origin)/llms-full.txt

            """.utf8)
        // RFC 9116. The security page describes a private disclosure process
        // in prose; this states the same thing where a scanner looks for it.
        out[".well-known/security.txt"] = Data("""
            Contact: mailto:\(Site.supportEmail)
            Expires: \(Site.securityContactExpires)
            Preferred-Languages: en
            Canonical: \(Site.origin)/.well-known/security.txt
            Policy: \(Site.origin)/security/

            """.utf8)
        // GitHub Pages needs both: the domain, and an instruction not to run
        // Jekyll over output that is already HTML.
        out["CNAME"] = Data("devdrivecacheclean.com\n".utf8)
        out[".nojekyll"] = Data()
        // IndexNow proves ownership by serving the key back at a URL under the
        // host being submitted. Written with no trailing newline: the file is
        // compared against the key itself, and a search engine that does not
        // trim would read a stray byte as the wrong key and refuse the whole
        // submission with a 403.
        out["\(Site.indexNowKey).txt"] = Data(Site.indexNowKey.utf8)
        return out
    }

    /// Test access to `allPages()`.` — or delete the shim entirely (L4)
    func allPages() throws -> [SitePage] {
        let pages = try authoredPages()
            + [LicencePage.page(licenceURL: licenceURL)]
            + DocumentationPages.pages(helpRoot: helpRoot)

        var slugs: Set<String> = []
        var outputPaths: Set<String> = []
        for page in pages {
            guard slugs.insert(page.slug).inserted, outputPaths.insert(page.outputPath).inserted else {
                throw SiteError.duplicateSlug(page.slug)
            }
        }
        return pages
    }

    private func authoredPages() throws -> [SitePage] {
        let manifest = try PageManifest.load(from: sourceRoot.appending(path: "meta.json"))
        return try manifest.pages.map { entry in
            let url = sourceRoot.appending(path: "pages/\(entry.file)")
            let body: String
            do {
                body = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw SiteError.missingFragment(entry.file, underlying: "\(error)")
            }
            // A fragment may open with its own head content, ended by a `<!--/head-->`
            // line.
            var head = ""
            var content = body
            if let marker = body.range(of: "<!--/head-->\n") {
                head = String(body[body.startIndex..<marker.lowerBound])
                content = String(body[marker.upperBound...])
            }
            // Expanded before Shell.render, so no unknown placeholder reaches the
            // shell.
            head = try head.replacingOccurrences(of: "{{faqStructuredData}}",
                                                 with: FAQ.structuredData())
            head = try head.replacingOccurrences(
                of: "{{softwareApplication}}",
                with: StructuredData.script(StructuredData.application))
            content = content.replacingOccurrences(of: "{{faqCards}}",
                                                   with: FAQ.cardsHTML)

            return SitePage(slug: entry.slug, title: entry.title,
                            description: entry.description, kind: entry.kind,
                            head: head.trimmingCharacters(in: .whitespacesAndNewlines),
                            body: content.trimmingCharacters(in: .newlines),
                            crumb: entry.crumb)
        }
    }

    private func sitemap(for pages: [SitePage]) -> String {
        // Sorted, so two runs of the builder cannot disagree about order.
        let urls = pages.filter(\.belongsInSitemap).map(\.canonical).sorted().map {
            "  <url><loc>\($0)</loc></url>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \(urls)
        </urlset>

        """
    }

    // MARK: - Assets

    /// The bytes one source asset contributes to the built site. CSS is
    /// minified (`CSSMinifier`); everything else — fonts, images — passes
    /// through unchanged. The single seam means the build and `drift` agree
    /// about what an asset should look like by construction.
    func assetOutput(of url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        guard url.pathExtension == "css", let source = String(data: bytes, encoding: .utf8) else {
            return bytes
        }
        return Data(CSSMinifier.minify(source).utf8)
    }

    /// Every asset the site ships, as its path relative to `assets/` → the
    /// bytes `assetOutput(of:)` produces for it.
    func assetOutputs() throws -> [String: Data] {
        let root = sourceRoot.appending(path: "assets")
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }

        let base = root.standardizedFileURL.path
        var out: [String: Data] = [:]
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            out[relative] = try assetOutput(of: url)
        }
        return out
    }

    // MARK: - Fonts

    /// Fails when the generated pages spell a character the shipped fonts do
    /// not carry, or when a font no longer matches the manifest that
    /// describes it. Runs on both the write and the check path, so a copy
    /// edit that outruns the subsets is a build failure rather than an empty
    /// box on the page.
    public func verifyFontCoverage() throws {
        let manifestURL = sourceRoot.appending(path: "fonts-manifest.json")
        let manifest = try JSONDecoder().decode(
            FontManifest.self, from: Data(contentsOf: manifestURL))
        var required = Set<UInt32>()
        for (path, data) in try files() where path.hasSuffix(".html") {
            required.formUnion(HTMLText.codepoints(in: String(decoding: data, as: UTF8.self)))
        }
        try FontCoverage.verify(manifest: manifest,
                                fontsDirectory: sourceRoot.appending(path: "assets/fonts"),
                                cover: required)
    }

    // MARK: - Writing and checking

    /// Builds the site into `output`. Returns the number of generated files
    /// (assets are mirrored, not counted).
    @discardableResult
    public func write(into output: URL) throws -> Int {
        try verifyFontCoverage()
        let fm = FileManager.default
        let built = try files()

        // Assets are copied wholesale rather than enumerated, so adding a
        // screenshot needs no code change; anything `assetOutput(of:)`
        // transforms (minified CSS) is then overwritten with its real
        // output, so the tree on disk and `drift`'s comparison agree.
        try? fm.removeItem(at: output.appending(path: "assets"))
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceRoot.appending(path: "assets"),
                        to: output.appending(path: "assets"))
        for (relative, data) in try assetOutputs() {
            try data.write(to: output.appending(path: "assets/\(relative)"))
        }

        for (path, data) in built {
            let url = output.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: url)
        }

        // Remove output the builder no longer produces, and any directory that empties.
        for path in try stale(in: output, built: Set(built.keys)) {
            try? fm.removeItem(at: output.appending(path: path))
        }
        try pruneEmptyDirectories(under: output)
        return built.count
    }

    /// Files in the output that the builder does not produce. `assets/` is skipped: it
    /// is mirrored wholesale, so nothing under it appears in `built`.
    func stale(in output: URL, built: Set<String>) throws -> [String] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }

        let base = output.standardizedFileURL.path
        var found: [String] = []
        for case let url as URL in walk {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if isUnderAssets(relative) { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if !built.contains(relative) { found.append(relative) }
        }
        return found.sorted()
    }

    /// True for `assets` itself or anything under it, by path component —
    /// not by substring, so a directory merely named `assets-old` does not
    /// also match.
    private func isUnderAssets(_ relative: String) -> Bool {
        relative == "assets" || relative.hasPrefix("assets/")
    }

    private func pruneEmptyDirectories(under output: URL) throws {
        let fm = FileManager.default
        let base = output.standardizedFileURL.path
        // Deepest first, so a directory emptied by removing its children is
        // itself removable in the same pass.
        let all = (fm.enumerator(at: output, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { url in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { return true }
                return !isUnderAssets(String(path.dropFirst(base.count + 1)))
            }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for dir in all where (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    /// Which generated files disagree with what is committed, assets included.
    public func drift(against output: URL) throws -> [String] {
        try verifyFontCoverage()
        let built = try files()
        var differing: [String] = []
        for (path, data) in built {
            let committed = try? Data(contentsOf: output.appending(path: path))
            if committed != data { differing.append(path) }
        }

        for (relative, data) in try assetOutputs() {
            let path = "assets/\(relative)"
            let committedURL = output.appending(path: path)
            let committedSize = try? committedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            // Cheap size check first; only read the bytes when it is inconclusive.
            let matches = committedSize == data.count && (try? Data(contentsOf: committedURL)) == data
            if !matches { differing.append(path) }
        }

        // Output the builder no longer produces is drift too.
        differing += try stale(in: output, built: Set(built.keys)).map { "\($0) (no longer built)" }
        return differing.sorted()
    }
}

