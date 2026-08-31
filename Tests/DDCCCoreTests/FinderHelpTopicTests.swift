import Testing
@testable import DDCCCore

@Test func everyFinderTopicHasNonEmptyCopyInBothForms() {
    for topic in FinderHelpTopic.allCases {
        #expect(topic.helpText.short.isEmpty == false, "\(topic) short")
        #expect(topic.helpText.long.isEmpty == false, "\(topic) long")
    }
}
