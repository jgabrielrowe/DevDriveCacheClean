import Foundation

/// Every codepoint a generated page can put on screen, with character
/// references resolved to the characters they stand for.
///
/// Attribute values are counted along with text. `title` and `alt` reach the
/// screen, and counting a character that never renders costs a few bytes in
/// the subset, where missing one shows the reader an empty box.
public enum HTMLText {
    private static let named: [String: UInt32] = [
        "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27,
        "nbsp": 0x00A0, "pound": 0x00A3, "yen": 0x00A5, "sect": 0x00A7,
        "copy": 0x00A9, "middot": 0x00B7, "mdash": 0x2014, "ndash": 0x2013,
        "ldquo": 0x201C, "rdquo": 0x201D, "lsquo": 0x2018, "rsquo": 0x2019,
        "hellip": 0x2026, "rarr": 0x2192, "euro": 0x20AC,
    ]

    public static func codepoints(in html: String) -> Set<UInt32> {
        var found = Set<UInt32>()
        var index = html.startIndex

        func keep(_ value: UInt32) {
            if value >= 0x20 { found.insert(value) }
        }

        while index < html.endIndex {
            let character = html[index]
            guard character == "&" else {
                for scalar in String(character).unicodeScalars { keep(scalar.value) }
                index = html.index(after: index)
                continue
            }
            guard let semicolon = html[index...].firstIndex(of: ";"),
                  html.distance(from: index, to: semicolon) <= 10
            else {
                keep(UInt32(UnicodeScalar("&").value))
                index = html.index(after: index)
                continue
            }
            let body = String(html[html.index(after: index)..<semicolon])
            if let value = resolve(body) {
                keep(value)
                index = html.index(after: semicolon)
            } else {
                keep(UInt32(UnicodeScalar("&").value))
                index = html.index(after: index)
            }
        }
        return found
    }

    private static func resolve(_ body: String) -> UInt32? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16)
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst(), radix: 10)
        }
        return named[body]
    }
}
