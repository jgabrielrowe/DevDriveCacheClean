import Testing
import Foundation

/// `UninstallPresentationTests` proved three functions carry the
/// right words and numbers — but nothing in that suite can see whether a
/// view file ever calls them. That gap is exactly where three defects lived: `trashResultDescription` had no call site outside
/// its own test, `evidenceStatement(for: UninstallDisplayRow)` was called
/// only for dead artifacts, and `report.completeness` was read once, only
/// to be copied into a rebuilt report, never to brand a symbol or a color.
/// "Tested" and "shown to a user" come apart silently unless something checks
/// that the wire exists.
///
/// This extends `ControlHelpTests`'s own precedent — read the view
/// directory as text, assert a pattern is present — to presentation
/// functions that carry one of this feature's binding rules (see
/// `UninstallPresentation.swift`'s "Rules That Bind This View"). It is
/// coarse: a source-text match proves a call site exists, not that it
/// renders correctly or reaches the screen under every state. That is
/// strictly more than the zero this suite could prove before.
@Test func theTrashResultWordingReachesAView() throws {
    let text = try viewsDirectoryText()
    #expect(
        text.contains("UninstallWording.trashResultDescription("),
        "Rule 1's wording function has no call site under Sources/DDCCUI/Views — nothing tells the user what happened after a Trash move."
    )
}

/// Every row states its evidence sources, so the list row for an app identity
/// must call the row-level evidence statement itself. The window below is
/// bounded to the `.app` case of the row renderer, so a call site that exists
/// only for `.deadArtifact` fails this.
@Test func everyAppRowRendersItsEvidenceStatement() throws {
    let window = try caseWindow(caseText: "case .app(let footprint):", in: "UninstallListView.swift")
    #expect(
        window.contains("evidenceStatement("),
        "UninstallListView's `.app` row never calls UninstallWording.evidenceStatement(for:) — an app row can carry a size and a name with nothing saying why the engine believes the app owns any of it."
    )
}

/// The Critical finding this guards: an unconditional green checkmark and
/// row count regardless of `ScanCompleteness` asserts a completeness the
/// sweep never checked. `isExact` is the one symbol that cannot appear in
/// the uninstall status tray without the branch existing — a `caveat` call
/// with no `isExact` check nearby would still let the checkmark lie.
@Test func theSweepTrayStatesWhetherItsCompletenessIsExact() throws {
    let window = try propertyWindow(declarationText: "private var uninstallStatusContent:", in: "SidebarView.swift")
    #expect(
        window.contains("isExact"),
        "SidebarView's uninstall status tray never reads ScanCompleteness.isExact — it can render a green checkmark for a sweep that could not read the whole disk."
    )
}

/// The two figures on a list row carry opposite meanings and identical
/// shapes, so swapping the calls that produce them is invisible to every
/// test that exercises the functions rather than the call sites: a row
/// reading "Reclaimable 9 MB / Retained 1 MB" the wrong way round compiles,
/// renders, and overstates the headline number — the specific dishonesty
/// this product exists to avoid.
///
/// The guard is a pairing rule, not a presence rule: each label literal
/// that interpolates a byte figure must name its *own* accessor on the same
/// line, and must not name the other one. That is why the view binds each
/// call inside its label's interpolation rather than through a local `let`
/// — a figure bound one line above its label can be swapped with its
/// neighbour and still look like correct code from any distance.
@Test func theListRowPairsEachLabelWithItsOwnFigure() throws {
    let lines = try viewsDirectoryText().components(separatedBy: .newlines)

    let reclaimable = lines.filter { $0.contains("\"Reclaimable \\(") }
    try #require(
        !reclaimable.isEmpty,
        "no view interpolates a figure into a \"Reclaimable \" label; this test would prove nothing")
    for line in reclaimable {
        #expect(
            line.contains("reclaimableBytes"),
            "a \"Reclaimable\" label is showing a figure that does not come from UninstallWording.reclaimableBytes(for:): \(line.trimmingCharacters(in: .whitespaces))")
        #expect(
            !line.contains("retainedBytes"),
            "a \"Reclaimable\" label is showing retained bytes — the headline number is overstated: \(line.trimmingCharacters(in: .whitespaces))")
    }

    let retained = lines.filter { $0.contains("\"Retained \\(") }
    try #require(
        !retained.isEmpty,
        "no view interpolates a figure into a \"Retained \" label; this test would prove nothing")
    for line in retained {
        #expect(
            line.contains("retainedBytes"),
            "a \"Retained\" label is showing a figure that does not come from UninstallWording.retainedBytes(for:): \(line.trimmingCharacters(in: .whitespaces))")
        #expect(
            !line.contains("reclaimableBytes"),
            "a \"Retained\" label is showing reclaimable bytes: \(line.trimmingCharacters(in: .whitespaces))")
    }
}

/// The same swap in the detail pane, where the label is a section headline
/// and the figure sits across a `Spacer()` from it, so no line carries
/// both. The section's own declaration is the window instead: the
/// Reclaimable section states one total, and that total must be the
/// reclaimable one.
@Test func theDetailPaneReclaimableTotalIsTheReclaimableFigure() throws {
    let window = try propertyWindow(
        declarationText: "private var reclaimableSection:", in: "UninstallDetailView.swift")
    #expect(
        window.contains("Text(\"Reclaimable\")"),
        "UninstallDetailView's reclaimable section no longer carries its own label; this test would prove nothing")
    #expect(
        window.contains("UninstallWording.reclaimableBytes(for: footprint)"),
        "UninstallDetailView's Reclaimable section states a total that does not come from UninstallWording.reclaimableBytes(for:)")
    #expect(
        !window.contains("retainedBytes"),
        "UninstallDetailView's Reclaimable section states retained bytes under a Reclaimable headline — the headline number is overstated")
}

/// The caveat is only a qualification if it is rendered next to the thing
/// it qualifies. `claimCaveatDescription(for:)` is exercised directly by
/// `aGroupContainerNothingScannedClaimsSaysSoRatherThanReadingAsSafe`, but
/// that test cannot see whether any view calls it — the same gap the rule
/// created this file for. The window is the detail pane's own item row,
/// which is where the size and the removal button both are.
@Test func anItemRowCarriesItsClaimCaveat() throws {
    let window = try propertyWindow(
        declarationText: "private func itemRow(", in: "UninstallDetailView.swift")
    #expect(
        window.contains("UninstallWording.claimCaveatDescription("),
        "UninstallDetailView's item row never calls UninstallWording.claimCaveatDescription(for:) — a group container no scanned app claims is offered under Reclaimable with a bare size, and the qualification the engine computed reaches nobody."
    )
}

/// the list-row half. A running app's footprint is `items: []`,
/// `retained: []` — so a row that renders the byte figures unconditionally
/// says "Reclaimable Zero KB" for an app that was never measured at all.
/// The `.app` case must reach for the refusal reason, and must gate the
/// figures on there being no refusal.
@Test func aRefusedRowShowsItsReasonInsteadOfAMeasuredZero() throws {
    let window = try caseWindow(caseText: "case .app(let footprint):", in: "UninstallListView.swift")
    #expect(
        window.contains("UninstallWording.refusalDescription("),
        "UninstallListView's `.app` row never calls UninstallWording.refusalDescription(for:) — a refused footprint renders as an app measured at zero."
    )
    #expect(
        window.contains("footprint.refusal == nil"),
        "UninstallListView's `.app` row renders its byte figures without checking `footprint.refusal` — a running app shows Reclaimable Zero KB, which is indistinguishable from an app genuinely measured at zero."
    )
}

/// the tray half. Apple-owned identities are dropped from the list,
/// so a tray reading `report.rows.count` would credit the sweep with ~220
/// rows the user can neither see nor act on.
@Test func theSweepTrayCountsTheRowsItActuallyListed() throws {
    let window = try propertyWindow(declarationText: "private var uninstallStatusContent:", in: "SidebarView.swift")
    #expect(
        window.contains("listedRowCount"),
        "SidebarView's uninstall tray does not read UninstallViewModel.listedRowCount — its row count includes identities the list drops."
    )
    #expect(
        !window.contains("report.rows.count"),
        "SidebarView's uninstall tray counts UninstallReport.rows, which includes the Apple-owned identities the list never shows."
    )
}

/// The Stop control itself. `UninstallViewModel.cancelSweep()` is exercised
/// by `stopCancelsTheRunningSweep`, but that test cannot see whether any
/// view offers the user a way to call it — and before this there was no
/// Stop control at all, unlike the Caches view. `ControlHelpTests` covers
/// the help text on it; this covers its existence.
@Test func theUninstallSweepCanBeStopped() throws {
    let text = try viewsDirectoryText()
    #expect(
        text.contains("viewModel.cancelSweep()"),
        "no view under Sources/DDCCUI/Views calls UninstallViewModel.cancelSweep() — a sweep the user cannot stop is one they abandon, and an abandoned sweep shows them no number at all."
    )
    // Asserted through the shared constant rather than the literal
    // "stop.fill": the three views take their glyphs from
    // `ActionGlyph` so they cannot drift apart, and a guard pinned to the
    // spelling would fail the moment that constant's value changed while the
    // convention it stands for held perfectly.
    #expect(
        text.contains("Label(\"Stop\", systemImage: ActionGlyph.stop)"),
        "the Uninstall view has no Stop control following the Caches view's convention."
    )
}

// MARK: - Shared source-scanning helpers

/// Both byte figures a user reads carry a hover hint explaining the term.
///
/// "Reclaimable" and "Retained" are this engine's own vocabulary — nothing on
/// screen defines either, and retain-until-last is the behaviour most likely to
/// be read as a bug. A `.help` string that exists but is attached to nothing
/// shows the user exactly as much as no string at all, which is the failure
/// this file was created to catch, so the attachment is what gets asserted
/// rather than the constants' existence.
///
/// Bound to the figures in the list row, not the detail pane: the list is where
/// both words first appear, and a user who never opens a detail pane still
/// meets them there.
@Test func bothByteFiguresExplainTheirTermOnHover() throws {
    let row = try propertyWindow(
        declarationText: "struct UninstallRowView", in: "UninstallListView.swift")
    let lines = row.components(separatedBy: .newlines)

    for (label, helpConstant) in [("Reclaimable", "reclaimableHelp"), ("Retained", "retainedHelp")] {
        let figure = try #require(
            lines.firstIndex(where: { $0.contains("Text(\"\(label) \\(") }),
            "UninstallRowView renders no \(label) figure; this test would prove nothing")
        // The hint has to sit on the figure itself, so the window is the
        // modifier chain: from the Text through to the next view or the end
        // of the chain. Scanning the whole row body would let a hint on some
        // other control satisfy this.
        let chain = lines[figure...].prefix(while: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return line == lines[figure] || trimmed.hasPrefix(".") || trimmed.isEmpty
                || trimmed.hasPrefix("//")
        })
        #expect(
            chain.contains(where: { $0.contains(".help(UninstallWording.\(helpConstant))") }),
            "The \(label) figure carries no .help; a user meets that word with nothing to explain it")
    }
}

private func viewsDirectoryURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // this file -> DDCCUILogicTests
        .deletingLastPathComponent()  // DDCCUILogicTests -> Tests
        .deletingLastPathComponent()  // Tests -> package root
        .appending(path: "Sources/DDCCUI/Views")
}

private func viewsDirectoryText() throws -> String {
    let views = try FileManager.default
        .contentsOfDirectory(at: viewsDirectoryURL(), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    try #require(!views.isEmpty, "no view files found; this test would prove nothing")
    return try views.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The text from a named `case` line up to (not including) the next `case`
/// or `private` declaration in the same file — the same bounded-window
/// technique `ControlHelpTests` uses to keep one control's `.help()` from
/// being credited to a different control. Deliberately not brace-bounded:
/// a `switch`'s `case` has no opening brace of its own to count, only the
/// next `case` keyword marks where its body ends.
private func caseWindow(caseText: String, in fileName: String) throws -> String {
    let url = viewsDirectoryURL().appending(path: fileName)
    let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    let start = try #require(
        lines.firstIndex(where: { $0.contains(caseText) }),
        "\(fileName) has no line containing \(caseText.debugDescription); this test would prove nothing")
    let after = lines.indices.dropFirst(start + 1)
    let end = after.first(where: { index in
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("case ") || trimmed.hasPrefix("private ")
    }) ?? lines.count
    return lines[start..<end].joined(separator: "\n")
}

/// The text of a `private var`/`private func` declaration's own block,
/// found by counting braces from the declaration line until the depth
/// returns to zero. Brace-bounded, unlike `caseWindow` above: a property
/// or function body is delimited by its own matching braces, not by the
/// next sibling declaration, and nested `HStack`/`VStack` closures inside
/// it would make a naive "next bare `}` line" search stop early, at the
/// first nested closure's own closing brace rather than the property's.
private func propertyWindow(declarationText: String, in fileName: String) throws -> String {
    let url = viewsDirectoryURL().appending(path: fileName)
    let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    let start = try #require(
        lines.firstIndex(where: { $0.contains(declarationText) }),
        "\(fileName) has no line containing \(declarationText.debugDescription); this test would prove nothing")

    var depth = 0
    var opened = false
    var end = lines.count - 1
    for index in start..<lines.count {
        for character in lines[index] {
            if character == "{" { depth += 1; opened = true }
            if character == "}" { depth -= 1 }
        }
        if opened && depth <= 0 {
            end = index
            break
        }
    }
    return lines[start...end].joined(separator: "\n")
}

/// Every path a view puts on screen is abbreviated to `~`, with one
/// deliberate exception.
///
/// The uninstall panes rendered `item.path.path` raw while the caches and
/// files lists went through `PathDisplay`, so the same machine's paths were
/// spelled two ways depending on which view you were in. Nothing could see
/// that: `PathDisplay` had tests, and the views that ignored it had none.
///
/// The exception is keyed to its label rather than to a file name, so
/// renaming the field withdraws the exemption on its own.
@Test func everyPathAViewShowsIsAbbreviatedUnlessLabelledFull() throws {
    let views = try FileManager.default
        .contentsOfDirectory(at: viewsDirectoryURL(), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    try #require(!views.isEmpty, "no view files found; this test would prove nothing")

    var checked = 0
    for view in views {
        let lines = try String(contentsOf: view, encoding: .utf8).components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.contains("Text(") && line.contains(".path") {
            checked += 1
            if line.contains("PathDisplay.tildeAbbreviated(") { continue }

            // A field labelled "Full Path" and selectable exists to be copied
            // into a terminal, where `~` would not expand inside quotes.
            let above = lines[max(0, index - 3)..<index].joined(separator: "\n")
            if above.contains(#"Text("Full Path")"#) { continue }

            let shown = line.trimmingCharacters(in: .whitespaces)
            Issue.record("\(view.lastPathComponent):\(index + 1) renders a raw path: \(shown)")
        }
    }

    #expect(checked >= 4, "found \(checked) path renders; expected the uninstall, dead-artifact and detail panes at minimum")
}

/// The inflected title is worthless if the sheet still interpolates its own.
@Test func theDeleteSheetUsesTheInflectedTitle() throws {
    let text = try viewsDirectoryText()
    #expect(text.contains("viewModel.deleteConfirmationTitle"))
    #expect(!text.contains(#"items?")"#), "a view still hard-codes a plural noun in a delete title")
}

/// Three call sites hold a path as a display string rather than a URL: both
/// engines' progress lines and a dead artifact's target. Each printed the
/// home directory until it was found in a screenshot.
@Test func everyDisplayStringPathIsAbbreviated() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sites = [
        "Sources/DDCCUI/ViewModels/AppViewModel.swift",
        "Sources/DDCCUI/ViewModels/FinderViewModel.swift",
        "Sources/DDCCUI/Models/UninstallPresentation.swift",
    ]
    for site in sites {
        let text = try String(contentsOf: root.appending(path: site), encoding: .utf8)
        #expect(text.contains("tildeAbbreviatedIfAbsolute("), "\(site) shows a raw path")
    }
}

