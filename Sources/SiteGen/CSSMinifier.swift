import Foundation

/// Minifies CSS on the way into `docs/`: strips comments, collapses
/// whitespace that carries no meaning, and drops the semicolon before a
/// closing brace. The source in `Site/assets/css` is never touched — this
/// only shapes `SiteWriter.assetOutput(of:)`'s output.
///
/// Three constructs are copied through byte-for-byte rather than reasoned
/// about, because getting them wrong is silent and visual: quoted strings
/// (the paper-grain `data:image/svg+xml` URI, every `content:"…"` literal)
/// and `calc(...)` expressions, where CSS requires the spaces around `+`
/// and `-`.
enum CSSMinifier {

    /// A chunk of source: ordinary declarations/selectors that can be
    /// rewritten freely, or a literal that must survive verbatim.
    private enum Segment {
        case code(String)
        case verbatim(String)
    }

    static func minify(_ source: String) -> String {
        let joined = segment(source).map { seg -> String in
            switch seg {
            case .code(let text): return collapse(text)
            case .verbatim(let text): return text
            }
        }.joined()

        var result = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        // The last declaration in a block never needs its semicolon. Looped
        // because a run of them (never seen in practice, but cheap to cover)
        // would otherwise leave one behind.
        while result.contains(";}") {
            result = result.replacingOccurrences(of: ";}", with: "}")
        }
        return result
    }

    // MARK: - Segmenting

    /// Splits `source` into rewritable code and protected literals: quoted
    /// strings and `calc(...)` expressions. A comment is dropped in place —
    /// replaced with a single space so it can never fuse two tokens —
    /// rather than becoming a segment of its own.
    private static func segment(_ source: String) -> [Segment] {
        let chars = Array(source)
        var segments: [Segment] = []
        var code = ""
        var i = 0

        func flushCode() {
            if !code.isEmpty {
                segments.append(.code(code))
                code = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") {
                    j += 1
                }
                i = min(j + 2, chars.count)
                code.append(" ")
                continue
            }

            if c == "\"" || c == "'" {
                flushCode()
                let (text, end) = scanString(chars, from: i, quote: c)
                segments.append(.verbatim(text))
                i = end
                continue
            }

            if isCalcStart(chars, at: i) {
                flushCode()
                let (text, end) = scanCalc(chars, from: i)
                segments.append(.verbatim(text))
                i = end
                continue
            }

            code.append(c)
            i += 1
        }
        flushCode()
        return segments
    }

    /// True at the `c` of a `calc(` that opens a function call, not the
    /// tail of some other identifier — a hypothetical `recalc(` would not
    /// match.
    private static func isCalcStart(_ chars: [Character], at i: Int) -> Bool {
        guard i + 5 <= chars.count, chars[i..<i + 5].elementsEqual("calc(") else { return false }
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        return !(prev.isLetter || prev.isNumber || prev == "_" || prev == "-")
    }

    /// Consumes a quoted string starting at `from` (the opening quote),
    /// honouring backslash escapes. Returns it — quotes included — with the
    /// index just past the closing quote.
    private static func scanString(_ chars: [Character], from: Int, quote: Character) -> (String, Int) {
        var i = from + 1
        var text = String(quote)
        while i < chars.count {
            let c = chars[i]
            text.append(c)
            i += 1
            if c == "\\", i < chars.count {
                text.append(chars[i])
                i += 1
                continue
            }
            if c == quote { break }
        }
        return (text, i)
    }

    /// Consumes a `calc(...)` starting at `from` (the `c` of `calc`),
    /// tracking nested parentheses — `var(--i, 0)` is common inside one —
    /// and nested strings, so a paren inside a literal cannot close the
    /// expression early. Returned verbatim, closing paren included.
    private static func scanCalc(_ chars: [Character], from: Int) -> (String, Int) {
        var i = from
        var text = ""
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                let (literal, end) = scanString(chars, from: i, quote: c)
                text += literal
                i = end
                continue
            }
            text.append(c)
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                i += 1
                if depth == 0 { break }
                continue
            }
            i += 1
        }
        return (text, i)
    }

    // MARK: - Collapsing ordinary code

    /// Collapses a run of whitespace to a single space, then drops that
    /// space wherever it sits against `{`, `}`, `;` or `,` — none of which
    /// need one outside a protected literal. Also trims the segment's own
    /// edges, which always meet either a structural character or the
    /// boundary of a string/`calc()` segment, never a value that depends on
    /// the space being there.
    private static func collapse(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isWhitespace {
                    j = text.index(after: j)
                }
                if !out.isEmpty, j < text.endIndex {
                    out.append(" ")
                }
                i = j
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        for tight in ["{", "}", ";", ","] {
            out = out.replacingOccurrences(of: " \(tight)", with: tight)
            out = out.replacingOccurrences(of: "\(tight) ", with: tight)
        }
        return out
    }
}
