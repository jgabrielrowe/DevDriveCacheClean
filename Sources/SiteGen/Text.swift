import Foundation

/// Escapes `&`, `<`, `>` and `"` for insertion as HTML markup text or an
/// attribute value. The one escaper for every renderer in this module.
func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Indents every non-empty line by `spaces`.
func indent(_ text: String, by spaces: Int) -> String {
    let pad = String(repeating: " ", count: spaces)
    return text.components(separatedBy: "\n")
        .map { $0.isEmpty ? $0 : pad + $0 }
        .joined(separator: "\n")
}
