import Testing
import Foundation

/// Replaces `DisabledControlHelpTests`, which asserted the opposite of the
/// truth. That test forbade pairing `.disabled()` with `.help()` on the claim
/// that macOS never shows a tooltip on a disabled control. Measured on
/// macOS 25.2 by hovering the three disabled toolbar controls in
/// a freshly launched DDCC with no scan run: all three showed their tooltips.
/// The claim was false, so the rule built on it — "tooltips never rescue what
/// is not legible" — went with it. A green test enforcing a false rule is
/// worse than a failing one: it reads as a guarantee and rejects correct code.
///
/// What replaces it is the true obligation: an interactive control should say
/// what it does.
///
/// Scope, stated rather than implied:
///   * Covers controls declared with a trailing-closure or `isOn:` label —
///     `Button {`, `Button(role:)`, `Toggle(isOn:)`, `Toggle("…")`, `Menu {`.
///   * Excludes `Button("Some Title")`, which is a menu item or a sheet button
///     whose visible title is its whole meaning ("Cancel", "Home Directory").
///   * Excludes `Picker`, whose entries live inside a `Menu` that carries the
///     help for the group.
///   * Does NOT cover sidebar rows. Those are `Label`s tagged for a
///     `List(selection:)`, not controls, so no source scan of this shape can
///     see them. Their tooltips are real but unguarded by this test.
///
/// The view list is read from the directory rather than hand-written, so a new
/// view file is covered the moment it exists.
@Test func everyInteractiveControlExplainsItself() throws {
    let viewsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ControlHelpTests.swift -> DDCCUILogicTests
        .deletingLastPathComponent()  // DDCCUILogicTests -> Tests
        .deletingLastPathComponent()  // Tests -> package root
        .appending(path: "Sources/DDCCUI/Views")

    let views = try FileManager.default
        .contentsOfDirectory(at: viewsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    try #require(!views.isEmpty, "no view files found; this test would prove nothing")

    let declarations = ["Button {", "Button(role:", "Toggle(isOn:", "Toggle(\"", "Menu {"]
    var controlsChecked = 0

    for url in views {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        let controlLines = lines.indices.filter { index in
            declarations.contains { lines[index].contains($0) }
        }

        for (position, index) in controlLines.enumerated() {
            // A control's modifiers run from its declaration to the start of
            // the next one, so a window bounded this way can never borrow the
            // `.help()` belonging to a different control.
            let end = position + 1 < controlLines.count ? controlLines[position + 1] : lines.count
            let window = lines[index..<end].joined(separator: "\n")
            controlsChecked += 1
            #expect(
                window.contains(".help("),
                "\(url.lastPathComponent):\(index + 1) is an interactive control with no .help(): \(lines[index].trimmingCharacters(in: .whitespaces))"
            )
        }
    }

    #expect(controlsChecked > 0, "no controls were examined, so this proved nothing")
}
