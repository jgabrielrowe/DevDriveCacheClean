import Foundation

public enum MarkdownError: Error, Equatable {
    /// Syntax outside the supported subset. Carries the 1-based line so the
    /// build failure names the page and the line rather than the file alone.
    case unsupported(line: Int, marker: String)
}

/// A deliberately closed Markdown subset.
///
/// Detection is by marker, not by parsing: prose passes through, and anything
/// that *looks* like Markdown this converter does not implement is an error.
/// The alternative — silent passthrough — ships a page with literal pipes in
/// it, and nobody reads their own help book carefully enough to catch that.
///
/// Supported: `#`/`##`/`###` headings, blank-line-separated paragraphs,
/// `- ` lists, fenced code blocks, and inline `` `code` ``, `**bold**`,
/// `*emphasis*`, `[text](url)`. Everything else throws.
public enum MarkdownSubset {

    /// Markers that mean "Markdown we do not support". Ordered longest-first
    /// so `####` is reported instead of `#`. Bullet and strikethrough markers
    /// are matched by their full form (`"* "`, `"+ "`, `"~~"`) rather than a
    /// bare prefix, because a bare `"*"` or `"~"` also matches supported
    /// content: `**bold**` and paths like `~/Library/Caches`.
    private static let rejectedPrefixes: [String] = [
        "####", "---", "![", "|", "* ", "+ ", "~~",
    ]

    public static func html(from markdown: String) throws -> String {
        var blocks: [String] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var note: [String] = []
        var fence: [String]?
        var lineNumber = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            let items = listItems.map { "<li>\(inline($0))</li>" }.joined(separator: "\n")
            blocks.append("<ul>\n\(items)\n</ul>")
            listItems = []
        }
        // An <aside>, not a <blockquote>: "> " is the authoring shorthand, but
        // the thing it marks is a note, and nothing in this help quotes anyone.
        // Both renderers receive this element; only their stylesheets differ.
        func flushNote() {
            guard !note.isEmpty else { return }
            blocks.append("<aside class=\"note\">\n<p>\(inline(note.joined(separator: " ")))</p>\n</aside>")
            note = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line == "```" {
                if let body = fence {
                    blocks.append("<pre><code>\(escape(body.joined(separator: "\n")))</code></pre>")
                    fence = nil
                } else {
                    flushParagraph(); flushList(); flushNote()
                    fence = []
                }
                continue
            }
            if fence != nil { fence?.append(rawLine); continue }

            if line.isEmpty { flushParagraph(); flushList(); flushNote(); continue }

            // The one permitted raw-HTML form: a bare anchor on its own line,
            // and nothing else. Matched exactly against what the emitter
            // produces — no wrapped content, no trailing text — so this is a
            // named exception rather than a hole in the rejection rule. The
            // anchor value is restricted to the character class every anchor
            // already satisfies (see HelpAnchor.swift / HelpAnchorTests).
            if line.range(of: #"^<a name="[a-z0-9-]+"></a>$"#, options: .regularExpression) != nil {
                flushParagraph(); flushList(); flushNote()
                blocks.append(line)
                continue
            }

            if let marker = rejectedMarker(in: line) {
                throw MarkdownError.unsupported(line: lineNumber, marker: marker)
            }

            if line.hasPrefix("### ") {
                flushParagraph(); flushList(); flushNote()
                blocks.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("## ") {
                flushParagraph(); flushList(); flushNote()
                blocks.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                flushParagraph(); flushList(); flushNote()
                blocks.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("- ") {
                flushParagraph(); flushNote()
                listItems.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("> ") {
                flushParagraph(); flushList()
                note.append(String(line.dropFirst(2)))
            } else {
                flushList(); flushNote()
                paragraph.append(line)
            }
        }
        flushParagraph(); flushList(); flushNote()
        return blocks.joined(separator: "\n")
    }

    private static func rejectedMarker(in line: String) -> String? {
        for prefix in rejectedPrefixes where line.hasPrefix(prefix) { return prefix }
        // "> " opens a note. A bare ">" is still a mistake, not a shorthand.
        if line.hasPrefix(">"), !line.hasPrefix("> ") { return ">" }
        // Ordered lists: a digit run followed by ". "
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return "\(digits)." }
        // Raw HTML: "<" immediately followed by a letter or a slash.
        if line.hasPrefix("<"), let second = line.dropFirst().first,
           second.isLetter || second == "/" {
            return String(line.prefix(while: { $0 != ">" }).prefix(4))
        }
        return nil
    }

    /// Internal rather than private so callers outside this file (BundleWriter's
    /// title emission) can reuse the same escaping instead of writing a second
    /// copy of these rules.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline conversion runs on escaped text, so a literal `<` in prose can
    /// never become a tag, and a `"` in a link's URL — including one crafted
    /// to close the `href` attribute early — can never inject a new
    /// attribute into the emitted `<a>` tag.
    ///
    /// `**bold**` is matched before `*emphasis*`: if the single-`*` pass ran
    /// first, it would consume `**bold**`'s two adjacent asterisks as a pair
    /// of (empty) emphasis markers before the bold pass ever saw them.
    private static func inline(_ text: String) -> String {
        var out = escape(text)
        out = replacePairs(in: out, delimiter: "**", open: "<strong>", close: "</strong>")
        out = replacePairs(in: out, delimiter: "*", open: "<em>", close: "</em>")
        out = replacePairs(in: out, delimiter: "`", open: "<code>", close: "</code>")
        out = replaceLinks(in: out)
        return out
    }

    private static func replacePairs(in text: String, delimiter: String,
                                     open: String, close: String) -> String {
        var out = ""
        var rest = Substring(text)
        var isOpen = true
        while let range = rest.range(of: delimiter) {
            out += rest[rest.startIndex..<range.lowerBound]
            out += isOpen ? open : close
            isOpen.toggle()
            rest = rest[range.upperBound...]
        }
        out += rest
        // An unpaired delimiter would leave a dangling tag; put it back.
        return isOpen ? out : text
    }

    private static func replaceLinks(in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let openBracket = rest.firstIndex(of: "["),
              let closeBracket = rest[openBracket...].firstIndex(of: "]"),
              rest.index(after: closeBracket) < rest.endIndex,
              rest[rest.index(after: closeBracket)] == "(",
              let closeParen = rest[closeBracket...].firstIndex(of: ")") {
            let label = rest[rest.index(after: openBracket)..<closeBracket]
            let href = rest[rest.index(closeBracket, offsetBy: 2)..<closeParen]
            out += rest[rest.startIndex..<openBracket]
            out += "<a href=\"\(href)\">\(label)</a>"
            rest = rest[rest.index(after: closeParen)...]
        }
        out += rest
        return out
    }
}
