import Testing
import Foundation
@testable import SiteGen

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SiteGenTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
}

private func siteCSS() throws -> String {
    try String(contentsOf: repoRoot().appending(path: "Site/assets/css/site.css"), encoding: .utf8)
}

/// The paper-grain background: an SVG `data:` URI inside `url("…")`. Its
/// spaces and `%`-escapes are part of the encoded document, not filler —
/// collapsing them changes the image.
@Test func theDataURIBackgroundSurvivesVerbatim() throws {
    let source = try siteCSS()
    let needle = #"url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.82' numOctaves='3'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)' opacity='.35'/%3E%3C/svg%3E")"#
    try #require(source.contains(needle), "fixture assumption changed: the data URI is not where this test expects it")

    let minified = CSSMinifier.minify(source)
    #expect(minified.contains(needle), "the paper-grain data URI was altered by minification")
}

/// CSS requires whitespace around a `calc()` expression's `+` and `-`
/// operators; removing it silently turns the declaration invalid and the
/// browser falls back to whatever it inherited.
@Test func calcExpressionsKeepTheirRequiredSpacing() throws {
    let source = try siteCSS()
    let calcExpressions = [
        "calc(100% + 11px)",
        "calc(var(--i, 0) * 40ms + 30ms)",
        "calc(100vh - var(--masthead-h))",
    ]
    for expression in calcExpressions {
        try #require(source.contains(expression),
                      "fixture assumption changed: \"\(expression)\" is not in site.css")
    }

    let minified = CSSMinifier.minify(source)
    for expression in calcExpressions {
        #expect(minified.contains(expression), "\"\(expression)\" lost its spacing under minification")
    }
}

/// `content:"…"` literals are rendered output — the readout's dash, "Menu",
/// the pseudo-headings — not code to be reformatted.
@Test func contentStringLiteralsSurviveVerbatim() throws {
    let source = try siteCSS()
    let literals = [
        #"content:"""#,
        #"content:"Menu""#,
        #"content:"Close""#,
        #"content:"—""#,
        #"content:"SCAN READOUT""#,
        #"content:"THE TERMS""#,
        #"content:"PRICE""#,
    ]
    for literal in literals {
        try #require(source.contains(literal),
                      "fixture assumption changed: \(literal) is not in site.css")
    }

    let minified = CSSMinifier.minify(source)
    for literal in literals {
        #expect(minified.contains(literal), "\(literal) was altered by minification")
    }
    // Twelve call sites in total (some of the seven distinct strings repeat).
    // Measured directly rather than assumed: `grep -c 'content:"'` on this
    // file returns 12, not the 13 the audit report estimated.
    let occurrences = source.components(separatedBy: "content:\"").count - 1
    #expect(occurrences == 12, "expected 12 content literals, found \(occurrences); hazard count assumption changed")
}

/// The build is committed to `docs/`, so two runs must agree exactly, not
/// just "close enough" — any nondeterminism would show up as permanent
/// drift the moment someone rebuilds.
@Test func minificationIsByteStableAcrossTwoRuns() throws {
    let source = try siteCSS()
    let first = CSSMinifier.minify(source)
    let second = CSSMinifier.minify(source)
    #expect(first == second)
    #expect(Data(first.utf8) == Data(second.utf8))
}

/// The saving must be at least the comments the source carries, since every
/// one of them is removed. Measured against the source rather than fixed at a
/// ratio: a ratio encodes how verbose the comments happen to be that week, and
/// shortening them would fail a test about the minifier.
@Test func minifiedOutputDropsAtLeastEveryCommentItRemoves() throws {
    let source = try siteCSS()
    let minified = CSSMinifier.minify(source)
    let sourceBytes = Data(source.utf8).count
    let minifiedBytes = Data(minified.utf8).count

    let commentBytes = source.ranges(of: try Regex(#"/\*[\s\S]*?\*/"#))
        .reduce(0) { $0 + Data(source[$1].utf8).count }
    #expect(commentBytes > 0, "no comments in the source; this test proves nothing")

    #expect(minifiedBytes < sourceBytes)
    #expect(sourceBytes - minifiedBytes >= commentBytes,
            "saved \(sourceBytes - minifiedBytes)B but the comments alone are \(commentBytes)B")
    #expect(!minified.contains("/*"), "a comment survived minification")
}

/// A run of consecutive semicolons before a close brace must not leave one
/// behind — the loop in `CSSMinifier.minify` exists for exactly this.
@Test func minifyDropsEveryTrailingSemicolonEvenWhenDoubled() {
    let minified = CSSMinifier.minify("a{color:red;;}")
    #expect(!minified.contains(";}"))
    #expect(minified == "a{color:red}")
}

/// A descendant combinator's space is meaningful (`.a .b` is not `.a.b`);
/// minification must collapse runs of whitespace, never delete a lone space
/// that isn't touching a structural character.
@Test func minifyPreservesTheDescendantCombinatorSpace() {
    let minified = CSSMinifier.minify(".masthead   nav   a{color:red}")
    #expect(minified == ".masthead nav a{color:red}")
}

/// A comment sitting directly between two selectors must not fuse them —
/// it is replaced with a single space, not deleted outright.
@Test func aCommentBetweenSelectorsDoesNotFuseThem() {
    let minified = CSSMinifier.minify(".a/* note */.b{color:red}")
    #expect(minified == ".a .b{color:red}")
}

/// Regression for the actual asset pipeline: `SiteWriter.assetOutput(of:)`
/// must minify `.css` and leave everything else — a font, here — untouched.
@Test func assetOutputMinifiesOnlyCSS() throws {
    let writer = SiteWriter(sourceRoot: repoRoot().appending(path: "Site"),
                            helpRoot: repoRoot().appending(path: "Help"))
    let css = try writer.assetOutput(of: repoRoot().appending(path: "Site/assets/css/site.css"))
    let source = try Data(contentsOf: repoRoot().appending(path: "Site/assets/css/site.css"))
    #expect(css.count < source.count)

    let font = repoRoot().appending(path: "Site/assets/fonts/IBMPlexMono-Regular.woff2")
    let fontOutput = try writer.assetOutput(of: font)
    #expect(fontOutput == (try Data(contentsOf: font)))
}

/// A malformed comment cost the site everything below `.pillar h3`: the browser
/// stopped parsing there, and the build, the minifier and the drift check all
/// stayed green because none of them reads CSS as CSS. Braces and comment
/// delimiters have to balance, and a rule near the end of the file has to
/// survive, or the tail is being silently discarded.
@Test func theStylesheetParsesAllTheWayToItsEnd() throws {
    let source = try siteCSS()

    // Comment delimiters, counted before anything else strips them.
    let opens = source.components(separatedBy: "/*").count - 1
    let closes = source.components(separatedBy: "*/").count - 1
    #expect(opens == closes, "\(opens) comment opens against \(closes) closes")

    // Outside comments, nothing may carry a stray delimiter or a backtick — the
    // exact residue a botched comment rewrite leaves behind.
    var stripped = ""
    var rest = Substring(source)
    while let open = rest.range(of: "/*") {
        stripped += rest[..<open.lowerBound]
        guard let close = rest[open.upperBound...].range(of: "*/") else { break }
        rest = rest[close.upperBound...]
    }
    stripped += rest
    #expect(!stripped.contains("*/"), "a stray */ sits outside any comment")
    #expect(!stripped.contains("`"), "a backtick sits in CSS, outside any comment")

    let braceOpens = stripped.filter { $0 == "{" }.count
    let braceCloses = stripped.filter { $0 == "}" }.count
    #expect(braceOpens == braceCloses, "\(braceOpens) { against \(braceCloses) }")

    // The last rule in the file must reach the minified output. When parsing
    // broke, `footer h2` was one of the rules silently lost.
    let minified = CSSMinifier.minify(source)
    for selector in ["footer h2{", ".colophon{", ".sr-only{"] {
        #expect(minified.contains(selector), "\(selector) is missing from the built stylesheet")
    }
}
