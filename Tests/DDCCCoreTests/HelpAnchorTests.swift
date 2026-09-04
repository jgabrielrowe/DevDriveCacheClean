import Testing
import Foundation
@testable import DDCCCore

private var allAnchors: [String] {
    RemovalTier.allCases.map(\.helpAnchor)
        + Removability.allCases.map(\.helpAnchor)
        + CleanCategory.allCases.map(\.helpAnchor)
        + FinderHelpTopic.allCases.map(\.helpAnchor)
}

@Test func everyAnchorIsUnique() {
    let anchors = allAnchors
    #expect(anchors.count == Set(anchors).count,
            "duplicate anchors: \(Dictionary(grouping: anchors, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
}

@Test func thereIsOneAnchorPerCatalogueEntry() {
    // 40 with Android. Hardcoded on purpose: a category added without
    // a help entry should fail here rather than ship undocumented.
    #expect(allAnchors.count == 40)
}

/// An anchor becomes an HTML `name` attribute and a lookup key for Help
/// Viewer. Anything outside this set either needs escaping or silently fails
/// to resolve.
@Test func everyAnchorIsALegalNameToken() {
    let legal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    for anchor in allAnchors {
        #expect(anchor.unicodeScalars.allSatisfy(legal.contains),
                "\(anchor) contains a character that is not lowercase, digit or hyphen")
        #expect(anchor.hasSuffix("-") == false, "\(anchor) ends in a hyphen")
    }
}

@Test func everyAnchorCarriesItsTypesPrefix() {
    for tier in RemovalTier.allCases {
        #expect(tier.helpAnchor.hasPrefix("tier-"), "\(tier.helpAnchor)")
    }
    for category in CleanCategory.allCases {
        #expect(category.helpAnchor.hasPrefix("category-"), "\(category.helpAnchor)")
    }
    for topic in FinderHelpTopic.allCases {
        #expect(topic.helpAnchor.hasPrefix("files-"), "\(topic.helpAnchor)")
    }
    for removability in Removability.allCases {
        #expect(removability.helpAnchor.hasPrefix("removability-"), "\(removability.helpAnchor)")
    }
}
