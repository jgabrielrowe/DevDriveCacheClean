import Testing
@testable import DDCCCore

@Test func oneTakesTheSingularAndEverythingElseTakesThePlural() {
    #expect(Plural.of(1, "item") == "1 item")
    #expect(Plural.of(2, "item") == "2 items")
    #expect(Plural.of(0, "item") == "0 items")
    #expect(Plural.of(67, "row") == "67 rows")
}

/// Negative counts are not expected, but a count that inflected as singular
/// at -1 would be a silent oddity rather than a visible one.
@Test func onlyExactlyOneIsSingular() {
    #expect(Plural.of(-1, "item") == "-1 items")
}

@Test func anIrregularNounCanBeGivenOutright() {
    #expect(Plural.of(1, "category", "categories") == "1 category")
    #expect(Plural.of(3, "category", "categories") == "3 categories")
}
