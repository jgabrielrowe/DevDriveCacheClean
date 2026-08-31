import Testing
import Foundation

/// The app's help and the website render the same HTML anddiffer only in CSS.
/// That is only true while it stays true: the website's stylesheet is written
/// for a marketing page — display serif, a warm paper ground, an accent colour
/// — and none of it belongs in a help book that must look like part of macOS.
///
/// This reads the shipped stylesheet as text and rejects the website's
/// vocabulary outright. Coarse, deliberately: the failure it guards is a
/// copy-paste between two files that look similar.
@Test func theHelpStylesheetDoesNotAdoptTheWebsitesLook() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // HelpBookGenTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appending(path: "Help/style.css")
    let css = try String(contentsOf: url, encoding: .utf8).lowercased()

    let forbidden = [
        "instrument serif", "instrument sans", "ibm plex",   // the site's faces
        "fonts.googleapis", "fonts.gstatic", "@import",      // any remote fetch
        "#f6f3ec", "#eeeae0",                                // the paper ground
        "#00246c", "#b4530e",                                // the site's blue and amber
        "--paper", "--amber", "--blue", "--serif",           // the site's tokens
        "fetureturbulence", "feturbulence",                  // the paper grain
    ]
    for token in forbidden {
        #expect(!css.contains(token), "Help/style.css contains \"\(token)\" — the website's styling has leaked into the app's help")
    }

    // Guard against the guard being vacuous.
    #expect(css.contains("aside.note"), "the note style is missing; this test would prove nothing about it")
    #expect(css.contains("-apple-system"), "the help book should use the system face")
}
