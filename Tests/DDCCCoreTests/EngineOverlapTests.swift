import Testing
import Foundation

/// No surface may sum a Caches total and an Uninstall total.
///
/// The Caches view and the Uninstall view can
/// each legitimately report the same bytes on disk — reclaiming an app's
/// caches and removing the app are different acts on the same data — but
/// no surface may ever *sum* the two totals into one number. Doing so
/// would report `Application Support/Claude` (12.1 GB, and already an
/// `appDeepClean` pattern via `Claude/vm_bundles`) claimed by both engines
/// as 23 GB, not the 12 GB it actually is.
@Test func noSurfaceSumsCachesAndUninstallTotals() throws {
    let violations = try summingViolations()
    let message =
        "found \(violations.count) place(s) where a Caches byte total and an "
        + "Uninstall byte total sit within a few lines of a \"+\", which is "
        + "how a surface would double-count the same bytes on disk:\n"
        + violations.joined(separator: "\n---\n")
    #expect(violations.isEmpty, "\(message)")
}

// MARK: - Guard implementation
//
// A preventive guard: nothing sums a Caches total with an Uninstall total
// today, and a test that only checked "no surface does this" would pass
// equally on a codebase with no summing logic at all. It was demonstrated to
// fail by adding a summing surface and watching it catch it.
//
// Source-scanning rather than a type-level barrier, because nothing aggregates
// `UninstallReport.rows` into one number; inventing that aggregate purely to
// wrap it would be scope this did not ask for. Both totals are plain `Int64`.
//
// Matches a bare `+`, not the spaced `" + "` form: the spaced form alone let
// `total += a; total += b` pass unseen, since `+=` never contains `" + "`. The
// token-window check below separates a real hit from harmless `+`s in literals
// and comments. Still invisible to it: a sum laundered through an intermediate
// variable, or hidden in a helper in a file this scan does not consider.

/// Caches-engine total-bytes vocabulary: the number a Caches surface would
/// show as "how much this scan can reclaim" — `AppViewModel.totalSize` and
/// the per-category subtotal `SidebarView` derives from it.
private let cachesTotalTokens = ["totalSize"]

/// Uninstall-engine total-bytes vocabulary: the number an app row shows as
/// "how much this app leaves reclaimable" (`AppFootprint.reclaimableBytes`,
/// via `UninstallWording.reclaimableBytes(for:)`), plus the one whole-sweep
/// figure `UninstallReport` carries that is not scoped to a single row
/// (`unattributedBytes`).
private let uninstallTotalTokens = ["reclaimableBytes", "unattributedBytes"]

/// How many lines on either side of a `+` count as "near enough" to be the
/// same expression. Generous enough to catch a sum built across two or
/// three statements (a local `let` on one line, added on the next), tight
/// enough that unrelated code elsewhere in the same file does not trip it.
private let windowRadius = 5

private func summingViolations() throws -> [String] {
    // Scoped to Sources/DDCCUI only, not the whole package. Verified, not
    // assumed: `AppViewModel.totalSize` (Caches) and `UninstallViewModel`'s
    // `report` (Uninstall) are only ever held in the same scope inside
    // `SidebarView`'s `ScanStatusBar` — no type under `Sources/DDCCCore`
    // references both engines' token vocabularies (grep confirms this: the
    // "totalSize" side and the "reclaimableBytes"/"unattributedBytes" side
    // are produced by disjoint files even within DDCCUI itself). If a
    // future change ever gives Core a combining role — a shared summary
    // type, a cross-engine report — that type would sit outside this scan
    // and this exclusion would need revisiting.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // this file -> DDCCCoreTests
        .deletingLastPathComponent()  // DDCCCoreTests -> Tests
        .deletingLastPathComponent()  // Tests -> package root
        .appending(path: "Sources/DDCCUI")

    let files = try swiftFiles(under: root)
    try #require(!files.isEmpty, "no DDCCUI source files found; this test would prove nothing")

    var violations: [String] = []
    for url in files {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.contains("+") {
            let start = max(0, index - windowRadius)
            let end = min(lines.count - 1, index + windowRadius)
            let window = lines[start...end].joined(separator: "\n")
            let hasCachesToken = cachesTotalTokens.contains { window.contains($0) }
            let hasUninstallToken = uninstallTotalTokens.contains { window.contains($0) }
            if hasCachesToken && hasUninstallToken {
                let path = url.path(percentEncoded: false)
                    .replacingOccurrences(of: root.path(percentEncoded: false) + "/", with: "")
                violations.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    return violations
}

private func swiftFiles(under directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil
    ) else {
        return []
    }
    var results: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        results.append(url)
    }
    return results.sorted { $0.path < $1.path }
}
