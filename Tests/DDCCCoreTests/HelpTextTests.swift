import Testing
import Foundation
@testable import DDCCCore

@Test func everyTierHasHelpInBothForms() {
    for tier in RemovalTier.allCases {
        let help = HelpText.for(tier)
        #expect(help.short.isEmpty == false, "\(tier)")
        #expect(help.long.isEmpty == false, "\(tier)")
    }
}

@Test func everyCategoryHasHelpInBothForms() {
    for category in CleanCategory.allCases {
        let help = HelpText.for(category)
        #expect(help.short.isEmpty == false, "\(category.rawValue)")
        #expect(help.long.isEmpty == false, "\(category.rawValue)")
    }
}

@Test func everyFinderElementHasHelpInBothForms() {
    for help in FinderHelpTopic.allCases.map(\.helpText) {
        #expect(help.short.isEmpty == false)
        #expect(help.long.isEmpty == false)
    }
}

/// The tooltip and the help book must render the same words, not two copies
/// of the same intent that drift apart.
@Test func tierHelpMatchesTheTierExplanationItDescribes() {
    for tier in RemovalTier.allCases {
        #expect(HelpText.for(tier).short == tier.explanation, "\(tier)")
    }
}

/// The Files view invites the reading "you have not used this". No help copy
/// may endorse it.
@Test func noHelpCopySaysUnused() {
    var all = FinderHelpTopic.allCases.map(\.helpText)
    all += RemovalTier.allCases.map { HelpText.for($0) }
    all += CleanCategory.allCases.map { HelpText.for($0) }
    for help in all {
        #expect(help.short.localizedCaseInsensitiveContains("unused") == false, "\(help.short)")
        #expect(help.long.localizedCaseInsensitiveContains("unused") == false, "\(help.long)")
    }
}

/// The grouping the sidebar draws must be the grouping the model states.
/// Derived from `isDeveloper` rather than restated, so a category cannot be
/// developer-owned in the model and system-owned in the heading above it.
@Test func everyCategoryGroupAgreesWithIsDeveloper() {
    for category in CleanCategory.allCases {
        #expect(CategoryGroup.of(category) == (category.isDeveloper ? .developer : .system))
    }
}

/// Both groups carry copy, in both lengths. `CleanCategory` is exhaustive by
/// switch for exactly this reason; a two-case enum can hide an empty string.
@Test func everyCategoryGroupExplainsWhatItHolds() {
    for group in CategoryGroup.allCases {
        #expect(!group.title.isEmpty)
        #expect(!group.helpText.short.isEmpty)
        #expect(!group.helpText.long.isEmpty)
        #expect(group.title.contains("Caches"), "the heading must say these are caches")
    }
}
