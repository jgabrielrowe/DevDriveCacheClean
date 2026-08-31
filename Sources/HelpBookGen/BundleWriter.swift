import Foundation

public enum HelpBookConstants {
    /// Must equal CFBundleHelpBookName in the app's Info.plist and the
    /// AppleTitle of index.html. Any disagreement opens an empty Help window
    /// with no error, which is why make-app.sh checks all three agree.
    public static let bookName = "DDCC Help"
    public static let folderName = "DDCC.help"
    public static let bundleIdentifier = "com.jgabrielrowe.devdrivecacheclean.help"
    public static let indexFilename = "DDCC.cshelpindex"
    public static let language = "en"
}

public enum BundleWriterError: Error, Equatable {
    case pageHasNoHeading(String)
    /// `Help/pages/` and `Help/generated/` are written into one flat directory,
    /// so a name in both would mean one page silently overwriting the other.
    case duplicatePageName(String)
}

public struct BundleWriter {
    private let pagesDirectory: URL
    private let generatedDirectory: URL
    private let styleSheet: URL

    public init(pagesDirectory: URL, generatedDirectory: URL, styleSheet: URL) {
        self.pagesDirectory = pagesDirectory
        self.generatedDirectory = generatedDirectory
        self.styleSheet = styleSheet
    }

    public func write(to destination: URL) throws {
        let resources = destination.appending(path: "Contents/Resources/\(HelpBookConstants.language).lproj")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        // Every page is read before any is written, because each one's nav
        // names all the others by title, and the titles live in the Markdown.
        var pages: [(name: String, title: String, body: String)] = []
        var seen: Set<String> = []
        for url in try markdownFiles(in: pagesDirectory) + markdownFiles(in: generatedDirectory) {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let title = try heading(of: markdown, filename: url.lastPathComponent)
            let name = url.deletingPathExtension().lastPathComponent
            guard seen.insert(name).inserted else {
                throw BundleWriterError.duplicatePageName(name)
            }
            pages.append((name, title, try MarkdownSubset.html(from: markdown)))
        }

        let titles = Dictionary(uniqueKeysWithValues: pages.map { ($0.name, $0.title) })
        for page in pages {
            let html = Self.page(
                title: page.title,
                body: page.body,
                nav: Self.nav(currentPage: page.name, titles: titles)
            )
            try html.write(to: resources.appending(path: "\(page.name).html"),
                           atomically: true, encoding: .utf8)
        }

        try FileManager.default.copyItem(at: styleSheet, to: resources.appending(path: "style.css"))
        try infoPlistData().write(to: destination.appending(path: "Contents/Info.plist"))
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The first `# ` line becomes AppleTitle. Without it Help Viewer shows the
    /// filename in search results.
    private func heading(of markdown: String, filename: String) throws -> String {
        guard let line = markdown.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("# ") }) else {
            throw BundleWriterError.pageHasNoHeading(filename)
        }
        return String(line.dropFirst(2))
    }

    /// The topics column, identical on every page but for which entry is the
    /// current one. Only pages actually present in this build are listed, so
    /// the nav can never point at a page that was not written; anything
    /// `Navigation` does not place still appears, at the end, rather than
    /// becoming unreachable.
    static func nav(currentPage current: String, titles: [String: String]) -> String {
        func entry(_ name: String) -> String {
            let label = MarkdownSubset.escape(titles[name] ?? name)
            return name == current
                ? "<li><span aria-current=\"page\">\(label)</span></li>"
                : "<li><a href=\"\(name).html\">\(label)</a></li>"
        }

        let present = Set(titles.keys)
        let unplaced = present.subtracting(Navigation.all).sorted()
        let topics = Navigation.topics.filter(present.contains) + unplaced
        let reference = Navigation.reference.filter(present.contains)

        var lines = ["<nav class=\"topics\">"]
        if present.contains(Navigation.home) {
            let label = MarkdownSubset.escape(titles[Navigation.home] ?? Navigation.home)
            lines.append(current == Navigation.home
                ? "<p class=\"book\"><span aria-current=\"page\">\(label)</span></p>"
                : "<p class=\"book\"><a href=\"\(Navigation.home).html\">\(label)</a></p>")
        }
        if !topics.isEmpty {
            lines.append("<ul>")
            lines.append(contentsOf: topics.map(entry))
            lines.append("</ul>")
        }
        if !reference.isEmpty {
            lines.append("<p class=\"group\">Reference</p>")
            lines.append("<ul>")
            lines.append(contentsOf: reference.map(entry))
            lines.append("</ul>")
        }
        lines.append("</nav>")
        return lines.joined(separator: "\n")
    }

    static func page(title: String, body: String, nav: String) -> String {
        // The title is interpolated into both an attribute value and element
        // text, so it needs the same escaping MarkdownSubset applies to every
        // other piece of page content — otherwise a heading containing `"`
        // can break out of `content="..."` in <head>.
        let escapedTitle = MarkdownSubset.escape(title)
        return """
        <!DOCTYPE html>
        <html lang="\(HelpBookConstants.language)">
        <head>
        <meta charset="utf-8">
        <meta name="AppleTitle" content="\(escapedTitle)">
        <title>\(escapedTitle)</title>
        <link rel="stylesheet" href="style.css">
        </head>
        <body>
        <div class="layout">
        \(nav)
        <main>
        \(body)
        </main>
        </div>
        </body>
        </html>
        """
    }

    private func infoPlistData() throws -> Data {
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": HelpBookConstants.language,
            "CFBundleIdentifier": HelpBookConstants.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": HelpBookConstants.bookName,
            "CFBundlePackageType": "BNDL",
            "HPDBookAccessPath": "index.html",
            "HPDBookIndexPath": HelpBookConstants.indexFilename,
            "HPDBookTitle": HelpBookConstants.bookName,
            "HPDBookType": "3",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
