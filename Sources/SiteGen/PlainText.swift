import Foundation

/// Turns a rendered page body back into readable markdown.
enum PlainTextError: Error {
    case noContentElement
}

enum PlainText {

    /// Furniture: dropped whole, with their children.
    private static let discarded = ["script", "style", "nav", "header", "footer", "aside"]

    static func markdown(from html: String) throws -> String {
        guard var text = contentElement(of: html) else {
            throw PlainTextError.noContentElement
        }

        for tag in discarded {
            text = removingElements(named: tag, from: text)
        }

        // A `role="img"` element's children are shapes, not sentences: the
        // price readout stacks twelve currencies that close up into
        // "$0.00€0,00£0.00…". The `aria-label` is what the element actually
        // means, and is already written for a reader who cannot see it.
        text = replacing(#"<(\w+)[^>]*\brole="img"[^>]*\baria-label="([^"]*)"[^>]*>(?:(?!</\1>).)*</\1>"#,
                         in: text, with: "\n\n$2\n\n")

        // Pagination is chrome. This file emits pages in the same order the
        // links point along, so repeating it as "PREVIOUS**04 · …**" states a
        // relationship the reader already has.
        text = removingElements(withClass: "pagenav", from: text)

        // alt text is the only readable content of a screenshot.
        text = replacing(#"<img[^>]*\balt="([^"]*)"[^>]*>"#, in: text, with: "\n[Screenshot: $1]\n")

        // The readouts set a number and its unit as adjacent spans, which would
        // otherwise close up into "48.72+GB".
        text = replacing("<span class=\"unit\">", in: text, with: " <span>")

        // Block structure, before the tags that carry it are stripped.
        for (level, tag) in [(1, "h1"), (2, "h2"), (3, "h3"), (4, "h4")] {
            let hashes = String(repeating: "#", count: level)
            text = replacing("<\(tag)[^>]*>", in: text, with: "\n\n\(hashes) ")
            text = replacing("</\(tag)>", in: text, with: "\n\n")
        }
        text = replacing("<li[^>]*>", in: text, with: "\n- ")
        text = replacing("<(p|div|section|tr|figcaption)[^>]*>", in: text, with: "\n\n")
        text = replacing("</(td|th)>\\s*<(td|th)[^>]*>", in: text, with: " — ")
        text = replacing("<br\\s*/?>", in: text, with: "\n")

        // <strong> carries the claim in a paragraph, so it survives as **.
        text = replacing("</?(strong|b)>", in: text, with: "**")
        text = replacing("</?(em|i)>", in: text, with: "*")
        text = replacing("</?code>", in: text, with: "`")

        text = replacing("<[^>]+>", in: text, with: "")
        text = unescaped(text)

        // Collapse the whitespace the substitutions left behind.
        text = replacing("[ \\t]+", in: text, with: " ")
        text = replacing(" ?\\n ?", in: text, with: "\n")
        text = replacing("\\n{3,}", in: text, with: "\n\n")
        text = replacing("\\*\\*\\s*\\*\\*", in: text, with: "")

        // The annotation cards set a label above its sentence with CSS alone:
        // `<b>Label</b>Sentence` has no separator in the source, so stripping
        // the tags fuses them into "**Label**Sentence". A newline restores the
        // break the design draws.
        text = replacing(#"\*\*([^*\n]+)\*\*(?=[A-Za-z])"#, in: text, with: "**$1**\n")

        // A figure is one fact: a caption naming what is shown, and alt text
        // describing it. Emitted as three orphan lines, nothing relates them.
        text = replacing(#"FIG\. \d+\n([^\n]+)\n\n\[Screenshot: ([^\]]+)\]"#,
                         in: text, with: "Figure — $1: $2")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The page's content element: `<main>`, or `<article>` for the guide. Closed on
    /// the last matching tag, not the first.
    private static func contentElement(of html: String) -> String? {
        for tag in ["main", "article"] {
            guard let open = html.range(of: "<\(tag)[^>]*>", options: .regularExpression),
                  let close = html.range(of: "</\(tag)>", options: .backwards),
                  open.upperBound <= close.lowerBound
            else { continue }
            return String(html[open.upperBound..<close.lowerBound])
        }
        return nil
    }

    /// Removes an element and its contents. Looped: the pattern is non-greedy, so one
    /// pass removes one element.
    private static func removingElements(named tag: String, from html: String) -> String {
        var text = html
        while let range = text.range(of: "<\(tag)\\b[^>]*>(.|\\n)*?</\(tag)>",
                                     options: [.regularExpression, .caseInsensitive]) {
            text.replaceSubrange(range, with: "\n")
        }
        return text
    }

    /// Removes an element carrying `class`, and everything inside it.
    ///
    /// Matched by class rather than by tag because the thing being dropped is a
    /// role, not an element type: `pagenav` is a `div` like the content around
    /// it, and only its class says it is furniture.
    private static func removingElements(withClass name: String, from html: String) -> String {
        var text = html
        let pattern = "<(\\w+)[^>]*\\bclass=\"[^\"]*\\b\(name)\\b[^\"]*\"[^>]*>(?:(?!</\\1>)[\\s\\S])*</\\1>"
        while let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            text.replaceSubrange(range, with: "\n")
        }
        return text
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement,
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// `&amp;` last, or an `&amp;lt;` in the source would decode twice and
    /// produce a tag that was never in the page.
    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&rarr;", with: "→")
            .replacingOccurrences(of: "&middot;", with: "·")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201D}")
            .replacingOccurrences(of: "&lsquo;", with: "\u{2018}")
            .replacingOccurrences(of: "&rsquo;", with: "\u{2019}")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
