import Testing
@testable import HelpBookGen

@Test func headingsBecomeHTags() throws {
    #expect(try MarkdownSubset.html(from: "# Title") == "<h1>Title</h1>")
    #expect(try MarkdownSubset.html(from: "## Section") == "<h2>Section</h2>")
    #expect(try MarkdownSubset.html(from: "### Detail") == "<h3>Detail</h3>")
}

@Test func consecutiveLinesFormOneParagraph() throws {
    let html = try MarkdownSubset.html(from: "One line\nand its continuation.")
    #expect(html == "<p>One line and its continuation.</p>")
}

@Test func blankLinesSeparateParagraphs() throws {
    let html = try MarkdownSubset.html(from: "First.\n\nSecond.")
    #expect(html == "<p>First.</p>\n<p>Second.</p>")
}

@Test func dashListsBecomeUnorderedLists() throws {
    let html = try MarkdownSubset.html(from: "- one\n- two")
    #expect(html == "<ul>\n<li>one</li>\n<li>two</li>\n</ul>")
}

@Test func inlineMarkupIsConverted() throws {
    let html = try MarkdownSubset.html(from: "Run `swift test` for **all** of it.")
    #expect(html == "<p>Run <code>swift test</code> for <strong>all</strong> of it.</p>")
}

@Test func linksBecomeAnchors() throws {
    let html = try MarkdownSubset.html(from: "See [the tiers](reference-tiers.html).")
    #expect(html == "<p>See <a href=\"reference-tiers.html\">the tiers</a>.</p>")
}

@Test func fencedBlocksBecomePreCode() throws {
    let html = try MarkdownSubset.html(from: "```\nnpm install\n```")
    #expect(html == "<pre><code>npm install</code></pre>")
}

@Test func htmlSpecialCharactersAreEscaped() throws {
    let html = try MarkdownSubset.html(from: "Fish & chips <not a tag>")
    #expect(html == "<p>Fish &amp; chips &lt;not a tag&gt;</p>")
}

/// The whole point of the closed subset. Silent passthrough would ship a page
/// with literal pipes in it; a build error costs a minute.
@Test func tablesAreRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "|")) {
        try MarkdownSubset.html(from: "| a | b |")
    }
}

@Test func otherUnsupportedMarkersAreRejected() {
    let cases: [(String, String)] = [
        // "> " is now a note; ">" without one is still a mistake.
        (">no space", ">"),
        ("* asterisk bullet", "* "),
        ("1. ordered item", "1."),
        ("#### fourth level", "####"),
        ("---", "---"),
        ("![image](x.png)", "!["),
        ("<div>raw html</div>", "<div"),
    ]
    for (source, marker) in cases {
        #expect(throws: MarkdownError.unsupported(line: 1, marker: marker)) {
            try MarkdownSubset.html(from: source)
        }
    }
}

@Test func theRejectedLineNumberIsReported() {
    #expect(throws: MarkdownError.unsupported(line: 3, marker: "|")) {
        try MarkdownSubset.html(from: "Fine.\n\n| a | b |")
    }
}

// MARK: - bold, strikethrough, and tilde-paths do not collide

@Test func aParagraphMayOpenWithBold() throws {
    let html = try MarkdownSubset.html(from: "**Safe** items can be selected in bulk.")
    #expect(html == "<p><strong>Safe</strong> items can be selected in bulk.</p>")
}

@Test func aTildePathIsOrdinaryProse() throws {
    let html = try MarkdownSubset.html(from: "~/Library/Caches holds per-user cache data.")
    #expect(html == "<p>~/Library/Caches holds per-user cache data.</p>")
}

@Test func asteriskBulletsAreStillRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "* ")) {
        try MarkdownSubset.html(from: "* bullet")
    }
}

@Test func strikethroughIsStillRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "~~")) {
        try MarkdownSubset.html(from: "~~strike~~")
    }
}

// MARK: - link URLs are HTML-safe

@Test func aQuoteInALinkURLIsEscapedNotInjected() throws {
    // The href value itself contains an unmatched "(" from the payload, which
    // is a separate, pre-existing simplification in replaceLinks (it matches
    // the first ")" rather than a balanced one) — unrelated to this fix. What
    // this test guards is the security property: the quote from the source
    // is escaped before replaceLinks ever sees it, so it can never close the
    // href attribute early and inject a live onmouseover attribute.
    let html = try MarkdownSubset.html(from: "[text](x\" onmouseover=\"alert(1))")
    #expect(html == "<p><a href=\"x&quot; onmouseover=&quot;alert(1\">text</a>)</p>")
    #expect(!html.contains("\" onmouseover=\""))
    #expect(!html.contains(" onmouseover=\"alert"))
}

@Test func aQuoteInASimpleLinkURLProducesAQuotedIntactHref() throws {
    let html = try MarkdownSubset.html(from: "[text](x\" onmouseover=\"bad)")
    #expect(html == "<p><a href=\"x&quot; onmouseover=&quot;bad\">text</a></p>")
}

@Test func fencedCodeQuotesAreEscapedLikeEverythingElse() throws {
    let html = try MarkdownSubset.html(from: "```\necho \"hi\"\n```")
    #expect(html == "<pre><code>echo &quot;hi&quot;</code></pre>")
}

@Test func paragraphQuotesAreEscaped() throws {
    let html = try MarkdownSubset.html(from: "She said \"hello\".")
    #expect(html == "<p>She said &quot;hello&quot;.</p>")
}

@Test func aBareAnchorLineIsPassedThrough() throws {
    let html = try MarkdownSubset.html(from: "<a name=\"tier-safe\"></a>")
    #expect(html == "<a name=\"tier-safe\"></a>")
}

@Test func otherRawHTMLIsStillRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "<div")) {
        try MarkdownSubset.html(from: "<div>still rejected</div>")
    }
}

/// The anchor exception must match nothing wider than the exact shape the
/// emitter produces. A script tag riding inside the anchor's own line would
/// otherwise pass straight through unescaped.
@Test func scriptInjectionInsideAnAnchorLineIsRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "<a n")) {
        try MarkdownSubset.html(from: "<a name=\"x\"><script>alert(1)</script></a>")
    }
}

@Test func otherTagsWrappedInsideAnAnchorLineAreRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "<a n")) {
        try MarkdownSubset.html(from: "<a name=\"x\"><b>bold</b></a>")
    }
}

@Test func trailingTextAfterAnAnchorLineIsRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "<a n")) {
        try MarkdownSubset.html(from: "<a name=\"x\"></a> trailing text")
    }
}

/// The anchor value is constrained to the character class every anchor in
/// `HelpAnchor.swift` already satisfies (lowercase letters, digits, hyphens).
@Test func anAnchorValueOutsideTheLegalCharacterClassIsRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "<a n")) {
        try MarkdownSubset.html(from: "<a name=\"Tier Safe\"></a>")
    }
}

@Test func aRawAnchorTagWithAnHrefIsStillRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "<a h")) {
        try MarkdownSubset.html(from: "<a href=\"x\">link</a>")
    }
}

// MARK: - single-asterisk emphasis

@Test func asteriskPairsBecomeEmphasis() throws {
    let html = try MarkdownSubset.html(from: "*text*")
    #expect(html == "<p><em>text</em></p>")
}

@Test func boldStillProducesStrongNotDoubledEmphasis() throws {
    let html = try MarkdownSubset.html(from: "**bold**")
    #expect(html == "<p><strong>bold</strong></p>")
}

@Test func emphasisAndBoldCanAppearInTheSameLine() throws {
    let html = try MarkdownSubset.html(from: "*a* and **b**")
    #expect(html == "<p><em>a</em> and <strong>b</strong></p>")
}

@Test func aParagraphMayOpenWithEmphasis() throws {
    let html = try MarkdownSubset.html(from: "*emphasis* opens the paragraph.")
    #expect(html == "<p><em>emphasis</em> opens the paragraph.</p>")
}

@Test func asteriskBulletsAreStillRejectedAlongsideEmphasis() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: "* ")) {
        try MarkdownSubset.html(from: "* bullet")
    }
}

/// The sentence that exposed the original gap: it shipped as literal
/// asterisks in Help/pages/files-view.md before this fix, and every existing
/// test passed because nothing exercised a leading single-asterisk pair.
@Test func theFilesViewSentenceConvertsWithNoLiteralAsterisk() throws {
    let html = try MarkdownSubset.html(
        from: "last *changed* — not when you last opened it.")
    #expect(html == "<p>last <em>changed</em> — not when you last opened it.</p>")
    #expect(!html.contains("*"))
}

/// "> " opens a note. The element is an <aside>, not a <blockquote>: the
/// marker is authoring shorthand and nothing in this help quotes anyone.
@Test func aNoteBecomesAnAside() throws {
    let html = try MarkdownSubset.html(from: "> **Careful.** This cannot be undone.")
    #expect(html == "<aside class=\"note\">\n<p><strong>Careful.</strong> This cannot be undone.</p>\n</aside>")
}

@Test func consecutiveNoteLinesJoinIntoOneParagraph() throws {
    let html = try MarkdownSubset.html(from: "> One line\n> and its continuation.")
    #expect(html.contains("<p>One line and its continuation.</p>"))
    #expect(html.components(separatedBy: "<aside").count - 1 == 1)
}

@Test func aBlankLineClosesTheNote() throws {
    let html = try MarkdownSubset.html(from: "> A note.\n\nOrdinary prose.")
    #expect(html == "<aside class=\"note\">\n<p>A note.</p>\n</aside>\n<p>Ordinary prose.</p>")
}

/// A note that runs straight into a heading or a paragraph still closes, so a
/// missing blank line cannot swallow the rest of the page.
@Test func aNoteClosesWhenSomethingElseStarts() throws {
    let html = try MarkdownSubset.html(from: "> A note.\n### Next\nProse.")
    #expect(html == "<aside class=\"note\">\n<p>A note.</p>\n</aside>\n<h3>Next</h3>\n<p>Prose.</p>")
}

/// Only "> " is the shorthand. A bare ">" is still a mistake, and the renderer
/// still refuses it rather than guessing.
@Test func aBareAngleBracketIsStillRejected() {
    #expect(throws: MarkdownError.unsupported(line: 1, marker: ">")) {
        try MarkdownSubset.html(from: ">no space")
    }
}
