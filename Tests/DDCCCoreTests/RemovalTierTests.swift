// Tests/DDCCCoreTests/RemovalTierTests.swift
import Testing
@testable import DDCCCore

@Test func tiersOrderBySeverity() {
    #expect(RemovalTier.safe < RemovalTier.costly)
    #expect(RemovalTier.costly < RemovalTier.destructive)
    #expect(RemovalTier.safe < RemovalTier.destructive)
}

@Test func worstTierInSelectionIsTheMaximum() {
    let selection: [RemovalTier] = [.safe, .destructive, .costly]
    #expect(selection.max() == .destructive)
}

@Test func maximumOfEmptySelectionIsNil() {
    let selection: [RemovalTier] = []
    #expect(selection.max() == nil)
}

@Test func everyTierHasNonEmptyLabelAndExplanation() {
    for tier in RemovalTier.allCases {
        #expect(tier.label.isEmpty == false)
        #expect(tier.explanation.isEmpty == false)
    }
}

@Test func tierCountIsThree() {
    #expect(RemovalTier.allCases.count == 3)
}
