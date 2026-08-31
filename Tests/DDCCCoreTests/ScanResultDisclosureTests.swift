import Testing
import Foundation
@testable import DDCCCore

private func row(sizeBytes: Int64, sharedBytesWithheld: Int64) -> ScanResult {
    ScanResult(
        path: URL(fileURLWithPath: "/tmp/project/node_modules"),
        category: .appCaches,
        tier: .safe,
        removability: .removable,
        sizeBytes: sizeBytes,
        lastModified: nil,
        displayName: "node_modules",
        partialRead: false,
        unreadablePaths: [],
        sharedBytesWithheld: sharedBytesWithheld,
        isDeletable: true
    )
}

@Test func aRowWithNothingWithheldSaysNothingAboutSharing() {
    let result = row(sizeBytes: 200_000, sharedBytesWithheld: 0)
    #expect(result.sharesContentElsewhere == false)
}

@Test func aRowHoldingLinkedContentSaysSo() {
    let result = row(sizeBytes: 200_000, sharedBytesWithheld: 4_000_000)
    #expect(result.sharesContentElsewhere == true)
    #expect(result.formattedSharedBytesWithheld.contains("MB"))
}

/// The withheld figure must never be folded back into the displayed size —
/// adding them reconstructs precisely the inflated number the sizing rule
/// exists to prevent.
@Test func theDisplayedSizeExcludesWithheldBytes() {
    let result = row(sizeBytes: 200_000, sharedBytesWithheld: 4_000_000)
    #expect(result.formattedSize == ByteCountFormatter.string(
        fromByteCount: 200_000, countStyle: .file))
}

/// Withholding is not a floor. A row that withheld bytes but read everything
/// must not wear the plus sign, which means something else entirely.
@Test func withheldBytesDoNotEarnThePlusSign() {
    let result = row(sizeBytes: 200_000, sharedBytesWithheld: 4_000_000)
    #expect(result.formattedSize.hasSuffix("+") == false)
}
