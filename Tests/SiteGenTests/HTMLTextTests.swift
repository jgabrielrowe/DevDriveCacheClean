import Testing
@testable import SiteGen

@Test func namedReferencesResolveToTheCharacterTheyRender() {
    let found = HTMLText.codepoints(in: "<p>a &mdash; b &middot; c</p>")
    #expect(found.contains(0x2014))
    #expect(found.contains(0x00B7))
    #expect(!found.contains(UInt32(UnicodeScalar("&").value)))
}

@Test func numericReferencesResolveInBothBases() {
    let found = HTMLText.codepoints(in: "&#269; &#x142;")
    #expect(found.contains(0x010D))
    #expect(found.contains(0x0142))
}

@Test func anUnknownReferenceKeepsItsLiteralCharacters() {
    let found = HTMLText.codepoints(in: "&notarealentity;")
    #expect(found.contains(UInt32(UnicodeScalar("&").value)))
    #expect(found.contains(UInt32(UnicodeScalar("n").value)))
}

@Test func controlCharactersAndNewlinesAreNotCounted() {
    let found = HTMLText.codepoints(in: "a\n\tb")
    #expect(!found.contains(0x0A))
    #expect(!found.contains(0x09))
    #expect(found.contains(UInt32(UnicodeScalar("a").value)))
}
