import Testing
import Foundation

/// No user-facing string interpolates a count straight into a hard-coded
/// plural noun.
///
/// Five did: the sidebar's category subtitle, both approval sheets, the trash
/// sheet's summary and the swept-rows readout. Three were legible in
/// screenshots taken for the website before anyone read them as a defect —
/// "Homebrew · 1 items". No unit test can see this class of mistake, because
/// each site is a correct string built by correct code; the error is only in
/// the English.
@Test func noStringInterpolatesACountIntoAHardCodedPlural() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // this file -> DDCCUILogicTests
        .deletingLastPathComponent()   // -> Tests
        .deletingLastPathComponent()   // -> package root

    let regex = try NSRegularExpression(
        pattern: #"\\\([^)]*[Cc]ount[^)]*\)\s+(items|files|folders|rows|apps|artifacts|categories|bytes)\b"#)

    var scanned = 0
    for directory in ["Sources/DDCCUI", "Sources/DDCCCore"] {
        let base = root.appending(path: directory)
        let walker = try #require(
            FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                // A site that inflects inline is correct without `Plural`.
                if line.contains("== 1") { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }
                let shown = line.trimmingCharacters(in: .whitespaces)
                Issue.record("\(url.lastPathComponent):\(index + 1) needs Plural.of — \(shown)")
            }
        }
    }

    #expect(scanned > 30, "scanned \(scanned) files; this test would prove nothing")
}
