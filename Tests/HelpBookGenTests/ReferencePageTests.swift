import Testing
import Foundation
@testable import HelpBookGen
@testable import DDCCCore

@Test func thereAreFourReferencePages() {
    #expect(ReferencePages.all.map(\.filename).sorted() == [
        "reference-categories.md",
        "reference-files.md",
        "reference-removability.md",
        "reference-tiers.md",
    ])
}

/// The reason the generator depends on DDCCCore rather than reading a dump:
/// every entry must reach the book, and the compiler is what guarantees it.
@Test func everyCatalogueEntryAppearsExactlyOnce() {
    let combined = ReferencePages.all.map(\.markdown).joined(separator: "\n")
    let entries = RemovalTier.allCases.map { HelpText.for($0).long }
        + Removability.allCases.map { HelpText.for($0).long }
        + CleanCategory.allCases.map { HelpText.for($0).long }
        + FinderHelpTopic.allCases.map(\.helpText.long)
    // A deliberate literal, not laziness. All four catalogue types are
    // CaseIterable, so `entries` grows on its own when a case is added --
    // and then this line fails, which is the point. It is a tripwire that
    // forces a decision about the new entry's copy, not an invariant.
    // A count derived from the same allCases the list is built from would
    // move on both sides at once and could never fail.
    #expect(entries.count == 39)
    for entry in entries {
        let occurrences = combined.components(separatedBy: entry).count - 1
        #expect(occurrences == 1, "expected 1 occurrence, found \(occurrences): \(entry.prefix(50))")
    }
}

@Test func everyAnchorAppearsInAReferencePage() {
    let combined = ReferencePages.all.map(\.markdown).joined(separator: "\n")
    let anchors = RemovalTier.allCases.map(\.helpAnchor)
        + Removability.allCases.map(\.helpAnchor)
        + CleanCategory.allCases.map(\.helpAnchor)
        + FinderHelpTopic.allCases.map(\.helpAnchor)
    for anchor in anchors {
        #expect(combined.contains("<a name=\"\(anchor)\"></a>"), "missing anchor \(anchor)")
    }
}

/// Every generated page must survive the converter. If one does not, the
/// build breaks at bundle assembly time with a much less obvious message.
@Test func everyReferencePageConverts() throws {
    for page in ReferencePages.all {
        #expect(throws: Never.self) { try MarkdownSubset.html(from: page.markdown) }
    }
}

/// The drift guard. Generated Markdown is committed so the pages users read
/// are reviewable as prose; this is what keeps the committed copy honest.
@Test func committedGeneratedPagesMatchTheEmitter() throws {
    let helpDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ReferencePageTests.swift -> HelpBookGenTests
        .deletingLastPathComponent()   // HelpBookGenTests -> Tests
        .deletingLastPathComponent()   // Tests -> package root
        .appending(path: "Help/generated")

    for page in ReferencePages.all {
        let url = helpDirectory.appending(path: page.filename)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Help/generated/\(page.filename) is missing. Regenerate with: swift run HelpBookBuilder --emit-markdown"
        )
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(
            committed == page.markdown,
            "Help/generated/\(page.filename) is stale. Regenerate with: swift run HelpBookBuilder --emit-markdown"
        )
    }
}
