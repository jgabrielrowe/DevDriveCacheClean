import Testing
import Foundation

/// The gap `ControlHelpTests` names in its own scope note: "Does NOT cover
/// sidebar rows. Those are `Label`s tagged for a `List(selection:)`, not
/// controls, so no source scan of this shape can see them. Their tooltips
/// are real but unguarded by this test."
///
/// This is that guard, plus the readout glyphs, which are not controls
/// either. It exists because driving the shipped app showed the need for
/// tooltips on the cache categories that already had them — which is the
/// symptom of a tooltip attached to something narrower than what a user
/// hovers, and exactly the failure `UninstallCallSiteTests` was created to
/// catch one level down: a help string that exists but hangs off the wrong
/// thing shows a user precisely as much as no help string at all.
///
/// Source-scanning, in the established style — read the view as text and
/// assert over it, rather than over a compiled `body` no test can evaluate.

private func viewSource(_ name: String) throws -> [String] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // this file -> DDCCUILogicTests
        .deletingLastPathComponent()  // DDCCUILogicTests -> Tests
        .deletingLastPathComponent()  // Tests -> package root
        .appending(path: "Sources/DDCCUI/Views/\(name)")
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
}

/// How far a modifier may sit from what it modifies. A SwiftUI view's
/// modifier chain runs down consecutive lines; four is enough for a chain
/// carrying a `.tag` and a `.contentShape` in between, tight enough that
/// one row cannot borrow its neighbour's `.help`.
private let chainWindow = 4

private func chain(_ lines: [String], from index: Int) -> String {
    lines[index..<min(lines.count, index + chainWindow + 1)].joined(separator: "\n")
}

/// Every selectable sidebar row says what it is. The sidebar is where a
/// user decides what to look at, and a row naming a category is the only
/// place that category is ever named before it is opened.
@Test func everySidebarRowExplainsItself() throws {
    let lines = try viewSource("SidebarView.swift")
    let tagged = lines.indices.filter { lines[$0].contains(".tag(SidebarSelection") }
    try #require(tagged.count >= 3, "expected the Files, Uninstall and All rows at minimum")

    for index in tagged {
        // A row's `.help` may precede its `.tag` as easily as follow it, so
        // the window looks both ways from the tag.
        let start = max(0, index - chainWindow)
        let window = lines[start..<min(lines.count, index + chainWindow + 1)].joined(separator: "\n")

        // A row whose content is its own view carries its tooltip there,
        // where the row is actually drawn. Named explicitly rather than
        // waved through by a looser window: `theCategoryRowHoverTargetIsTheWholeRow`
        // is what covers this one, and if `CategoryRow` is ever inlined back
        // into the sidebar this exemption stops applying on its own.
        if window.contains("CategoryRow(") { continue }

        #expect(
            window.contains(".help("),
            """
            a sidebar row at SidebarView.swift:\(index + 1) has no tooltip. \
            Every row a user can select should say what selecting it shows:
            \(window)
            """)
    }
}

/// The category row's tooltip must hang off the whole row, not off the
/// `Label`'s drawn content. Without `.contentShape`, hovering the row's
/// trailing figures — or the empty gap the `Spacer` opens between name and
/// size — shows nothing, and a tooltip that appears over part of a row
/// reads to a user as no tooltip at all.
///
/// Mutation: deleting the `.contentShape(Rectangle())` line fails this with
/// the row's source printed.
@Test func theCategoryRowHoverTargetIsTheWholeRow() throws {
    let lines = try viewSource("SidebarView.swift")
    let index = try #require(
        lines.firstIndex { $0.contains("struct CategoryRow") },
        "CategoryRow has been renamed; this guard no longer covers it")
    let end = lines[index...].firstIndex { $0.contains("private var subtitle") } ?? lines.count
    let body = lines[index..<end].joined(separator: "\n")

    #expect(body.contains(".contentShape("), "CategoryRow's tooltip covers only its drawn content")
    #expect(body.contains(".help("), "CategoryRow has no tooltip at all")
}

/// The completeness marker and its caveat line. The marker distinguishes a
/// measured total from a floor by hue alone — green against orange — and
/// the caveat names up to three separate mechanisms in a handful of words.
/// Neither is defined anywhere else on screen.
@Test func theCompletenessReadoutExplainsItself() throws {
    let lines = try viewSource("SidebarView.swift")

    let markers = lines.indices.filter {
        lines[$0].contains("checkmark.circle.fill") || lines[$0].contains("xmark.circle.fill")
    }
    try #require(!markers.isEmpty, "the completeness markers have moved; this guard is blind")

    for index in markers {
        #expect(
            chain(lines, from: index).contains(".help("),
            """
            the completeness marker at SidebarView.swift:\(index + 1) has no tooltip. \
            It differs from the other state by colour alone:
            \(chain(lines, from: index))
            """)
    }

    let caveat = try #require(
        lines.firstIndex { $0.contains("completeness.caveat") && $0.contains("if let") },
        "the caveat line has moved; this guard is blind")
    #expect(
        lines[caveat..<min(lines.count, caveat + 8)].joined(separator: "\n").contains(".help("),
        "the caveat line names its mechanisms but defines none of them")
}

/// The second glyph in each list row — the one beside the selection
/// control. Both were silent while the control next to them explained
/// itself, which is the shape of the omission rather than a coincidence:
/// the control was written as a control and the glyph as decoration, and a
/// glyph carrying the only statement of what kind of thing a row is is not
/// decoration.
@Test func everyListRowGlyphExplainsItself() throws {
    for (view, needle) in [
        ("ResultsListView.swift", "result.category.icon"),
        ("FinderListView.swift", "file.isBundle ?"),
    ] {
        let lines = try viewSource(view)
        let index = try #require(
            lines.firstIndex { $0.contains("Image(systemName:") && $0.contains(needle) },
            "\(view)'s row glyph has moved; this guard is blind")
        #expect(
            chain(lines, from: index).contains(".help("),
            """
            the row glyph at \(view):\(index + 1) has no tooltip, while the \
            control beside it has one:
            \(chain(lines, from: index))
            """)
    }
}

/// The header is the hit target, not the disclosure arrow alone. Every
/// other outline view on macOS toggles on the title too, and the arrow is a
/// small target for something whose meaning is the whole header.
@Test func theSidebarSectionHeaderTogglesOnTheWholeHeader() throws {
    let lines = try viewSource("SidebarView.swift")
    let index = try #require(
        lines.firstIndex { $0.contains("struct SidebarSectionHeader") },
        "SidebarSectionHeader has been renamed; this guard no longer covers it")
    let end = lines[index...].firstIndex { $0.hasPrefix("}") && $0.count == 1 } ?? lines.count
    let body = lines[index..<end].joined(separator: "\n")

    // Without `.contentShape` the tap lands only on the glyphs of the word,
    // not on the gap between the title and the arrow — which is most of the
    // header's width and all of what a user aims at.
    #expect(body.contains(".contentShape("), "the header's hit target is the text's own glyphs")
    #expect(body.contains(".onTapGesture"), "the header title does not toggle anything")
    #expect(body.contains(".help("), "the section header does not say what the group holds")
}

/// A section title spelled in the view as well as in `CategoryGroup` is two
/// places to rename and one of them will be missed. This is the rename that
/// asked for — "Developer" to "Developer Caches" — and the reason it is
/// worth a guard is that the sidebar holds Files and Uninstall rows too, so
/// the word "Caches" in the heading is load bearing rather than decorative.
@Test func theSidebarDoesNotSpellItsSectionTitlesItself() throws {
    let lines = try viewSource("SidebarView.swift")
    for stale in ["Text(\"Developer\")", "Text(\"System & Apps\")", "Text(\"Developer Caches\")"] {
        #expect(
            !lines.contains { $0.contains(stale) },
            "SidebarView spells a section title itself (\(stale)); CategoryGroup owns it")
    }
}

/// One glyph for the act of starting work, across all three views.
///
/// Two of them used `magnifyingglass` — the symbol macOS itself draws inside
/// the search field a few points away — so a button that scans the disk and
/// a field that filters what is already on screen showed the same icon while
/// doing unrelated things. That reads as jarring on first use, so
/// for one symbol across all three, so moving between views does not mean
/// working out afresh which control starts the work.
@Test func theThreeStartControlsShareOneGlyph() throws {
    for (view, label) in [
        ("MainToolbar.swift", "Scan"),
        ("FinderToolbar.swift", "Find"),
        ("UninstallListView.swift", "Sweep"),
    ] {
        let lines = try viewSource(view)
        let index = try #require(
            lines.firstIndex { $0.contains("Label(\"\(label)\", systemImage:") },
            "\(view)'s start control has been renamed; this guard is blind")
        #expect(
            lines[index].contains("ActionGlyph.startSweep"),
            """
            \(view):\(index + 1) names its own glyph rather than sharing one:
            \(lines[index].trimmingCharacters(in: .whitespaces))
            """)
    }
}

/// `magnifyingglass` is spoken for. Compound symbols that merely contain the
/// word — `doc.text.magnifyingglass` for an empty Files result — are a
/// different glyph and are left alone; this is the bare one, which is the
/// search field's.
@Test func noControlReusesTheSearchFieldGlyph() throws {
    let viewsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/DDCCUI/Views")
    let views = try FileManager.default
        .contentsOfDirectory(at: viewsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    try #require(!views.isEmpty)

    for url in views {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        for (number, line) in lines.enumerated() where line.contains("\"magnifyingglass\"") {
            Issue.record("""
                \(url.lastPathComponent):\(number + 1) uses the search field's own glyph:
                \(line.trimmingCharacters(in: .whitespaces))
                """)
        }
    }
}

/// All three views offer their start control in the empty pane, not only in
/// the toolbar. Uninstall has done this since it shipped and it is what
/// The other two match it: the empty pane is where the eye
/// already is, and pointing at a toolbar is a worse answer than being the
/// button.
@Test func everyEmptyPaneOffersItsOwnStartControl() throws {
    for (view, call) in [
        ("ResultsListView.swift", "viewModel.startScan()"),
        ("FinderListView.swift", "viewModel.startFind()"),
        ("UninstallListView.swift", "viewModel.startSweep()"),
    ] {
        let lines = try viewSource(view)
        let index = try #require(
            lines.firstIndex { $0.contains("Button(") && $0.contains(call) },
            "\(view)'s empty pane has no button that starts a run")
        // Inside a `ContentUnavailableView`, not loose in the body: the
        // toolbar's own control also calls this, and a guard that could not
        // tell them apart would pass on the toolbar alone.
        let preceding = lines[max(0, index - 12)..<index].joined(separator: "\n")
        #expect(
            preceding.contains("ContentUnavailableView"),
            "\(view):\(index + 1) starts a run but not from the empty pane")
    }
}

/// An empty Files list means one of four different things, and the view has
/// now stated the wrong one twice: first a stopped run, then a run that was
/// still going, both described as having found nothing. Each time the state
/// nobody wrote a branch for fell through to the same trailing `else`.
///
/// So the guard is no longer "does an idle branch exist" — it is that the view
/// reaches its answer through `ScanState.emptyResultsReason`, whose `switch` is
/// exhaustive and has no `default`. A fifth state cannot compile until this
/// view decides what it means, which is the property a chain of `if case`
/// tests could never have.
@Test func theFilesViewAnswersForEveryEmptyState() throws {
    let source = try viewSource("FinderListView.swift").joined(separator: "\n")
    #expect(
        source.contains("viewModel.state.emptyResultsReason"),
        "Files chooses its empty message without consulting emptyResultsReason")
    for reason in ["case .notSearchedYet:", "case .stillSearching:",
                   "case .stopped:", "case .searchedAndFoundNothing:"] {
        #expect(source.contains(reason), "Files has no branch for \(reason)")
    }
    #expect(source.contains("No Files Found"), "Files no longer states a genuinely empty result")
    // The one that was missing, named so a regression reads as itself.
    #expect(source.contains("Searching…"), "Files states a result while a run is still going")
}

/// A dead artifact's pane has to be reachable, and its buttons have to call
/// something. The removal logic is covered by
/// `movingADeadArtifactToTheTrashRemovesItsRow` and its neighbours, and none
/// of those tests can see whether any view ever renders the pane or wires the
/// action — the suite cannot see call sites, so correct tested logic that
/// nothing calls shows the user exactly nothing.
@Test func theDeadArtifactPaneIsReachableAndItsActionsAreWired() throws {
    let window = try viewSource("MainWindow.swift").joined(separator: "\n")
    #expect(
        window.contains("DeadArtifactDetailView("),
        "no view renders DeadArtifactDetailView, so selecting a dead artifact shows the empty pane")
    #expect(
        window.contains("uninstallViewModel.selectedDeadArtifact"),
        "MainWindow never asks for the selected dead artifact")

    let pane = try viewSource("DeadArtifactDetailView.swift").joined(separator: "\n")
    #expect(
        pane.contains("viewModel.moveToTrash(deadArtifact:"),
        "the dead-artifact pane has no Trash action")
    #expect(
        pane.contains("viewModel.removePermanently(deadArtifact:"),
        "the dead-artifact pane has no permanent-removal action")
    // The same rule the app pane follows: a permanent deletion is confirmed,
    // a Trash move is not.
    #expect(
        pane.contains(".confirmationDialog("),
        "permanent deletion of a dead artifact is not confirmed")
}

/// The expand animation fix, kept from being tidied away.
///
/// Rows descended from the top of the sidebar column instead of unfolding
/// under their header. A five-variant probe cleared everything this view
/// does — the bottom tray, the `if !categories.isEmpty` wrappers, the
/// computed selection binding, `NavigationSplitView` — and reproduced it on
/// a bare `List { Section(isExpanded:) }`. A `DisclosureGroup` and an
/// explicit `.transition` both failed on the same fixture; suppressing the
/// transaction was the only thing that worked.
///
/// This line looks like a stray performance tweak to anyone who did not run
/// that probe, which is exactly the kind of line that gets deleted during a
/// tidy-up. Removing it does not fail any behavioural test — no test can
/// watch an animation — so it fails this one instead.
@Test func theSidebarSuppressesTheSectionExpandAnimation() throws {
    let lines = try viewSource("SidebarView.swift")
    let index = try #require(
        lines.firstIndex { $0.contains(".transaction {") && $0.contains("animation = nil") },
        """
        SidebarView no longer suppresses its animation transaction. If that \
        was deliberate, check first that expanding a section below the top of \
        the list no longer flies its rows in from y=0 — no test can see it.
        """)

    // On the List, not on a Section. The disclosure control starts the
    // transaction outside the section, so a `.transaction` scoped to one
    // never sees it — which is why the suppression is list-wide and why
    // narrowing it would silently stop working.
    let listStart = try #require(lines.firstIndex { $0.contains("List(selection: selection)") })
    #expect(
        index > listStart,
        "the transaction must modify the List; scoped to a Section it never sees the disclosure's own")
}

/// The quit controls have to be rendered and wired, for the same reason the
/// dead-artifact pane needed a guard: the view model's `quit` is covered by
/// four tests, none of which can see whether any view offers the user a way
/// to call it. Before this, a running app's pane stated a refusal and gave
/// no way out of it.
@Test func theRunningAppPaneOffersAWayOutOfTheRefusal() throws {
    let pane = try viewSource("UninstallDetailView.swift").joined(separator: "\n")
    #expect(pane.contains("viewModel.quit(footprint, force: false)"), "no plain Quit control")
    #expect(pane.contains("viewModel.quit(footprint, force: true)"), "no Force Quit control")
    #expect(pane.contains("viewModel.quitResult(for: footprint)"), "the pane never reports the outcome")
    // Force quitting discards unsaved work, so it is confirmed — the same
    // bar permanent deletion clears, and for the same reason.
    #expect(
        pane.contains("showForceQuitConfirmation"),
        "force quit is not confirmed, though it loses unsaved work without warning")
}

/// The authentication notice is engine-side truth the user can only act on if
/// a view draws it. `requiresAuthentication` is covered by tests in
/// `DDCCCoreTests`, none of which can see whether any row says so — and a
/// password dialog nobody warned about is the failure mode.
@Test func theAuthenticationNoticeAndItsCaveatAreBothRendered() throws {
    let pane = try viewSource("UninstallDetailView.swift").joined(separator: "\n")
    #expect(
        pane.contains("item.requiresAuthentication"),
        "no row tells the user macOS will ask for a password")
    #expect(
        pane.contains("UninstallWording.authenticationNotice"),
        "the row does not use the shared wording")
    // The permanent-deletion path skips such an app rather than removing it,
    // so the confirmation must say so before the user commits.
    #expect(
        pane.contains("UninstallWording.permanentRemovalCaveat(for: footprint)"),
        "permanent deletion never warns that the app itself will be skipped")
}

/// The Finder route is dead without this key: macOS denies the Apple Event
/// outright rather than prompting, so removing a pkg-installed app would fail
/// with a permission error no amount of authenticating could clear. Nothing in
/// the Swift sources can express that dependency, so it is asserted here.
@Test func theBundleDeclaresWhyItSendsAppleEvents() throws {
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Resources/Info.plist")
    let contents = try String(contentsOf: plist, encoding: .utf8)

    #expect(
        contents.contains("NSAppleEventsUsageDescription"),
        "without this key macOS denies the Apple Event instead of prompting")
    // The string is shown verbatim in the system prompt, so it has to say what
    // DDCC will do with the permission, not merely that it wants it.
    #expect(contents.contains("Finder"), "the usage description does not name what it controls")
}

/// The menu bar is declared in one place and nothing else can see it.
///
/// The pasteboard group must stay: measured against a probe with it removed,
/// ⌘V does nothing in a text field, because the menu items carry the key
/// equivalents. DDCC has three filter fields and the confirmation field that
/// requires typing DELETE, so removing it would break paste in all four with
/// no compile error and no failing test.
@Test func theMenuKeepsPasteAndDropsWhatTheAppCannotDo() throws {
    let app = try URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/DDCCUI/DDCCApp.swift")
    let source = try String(contentsOf: app, encoding: .utf8)

    #expect(
        source.contains("CommandGroup(replacing: .pasteboard)") == false,
        "removing the pasteboard group breaks ⌘V in every text field")

    for group in [".newItem", ".undoRedo", ".textEditing", ".toolbar"] {
        #expect(
            source.contains("CommandGroup(replacing: \(group)) {}"),
            "\(group) is a document-editor default this app has no use for")
    }

    // Replacing this one is what builds the Format menu, as an empty container
    // SwiftUI restores as fast as AppKit can remove it. Left alone, no Format
    // menu is created. Measured with a probe that dumps `NSApp.mainMenu`.
    #expect(
        source.contains("CommandGroup(replacing: .textFormatting) {}") == false,
        "replacing .textFormatting creates the empty Format menu it looks like it removes")

    // The three verbs must reach the view models, or the menu names actions it
    // cannot perform.
    #expect(source.contains("viewModel.startScan()"))
    #expect(source.contains("finderViewModel.startFind()"))
    #expect(source.contains("uninstallViewModel.startSweep()"))

    // All three are offered at once and named for what they scan, not for the
    // view they belong to.
    for title in ["Scan Caches", "Find Large Files", "Sweep Installed Apps"] {
        #expect(source.contains("Button(\"\(title)\")"), "\(title) is missing from the menu")
    }

    // SwiftUI files the sidebar toggle under Help rather than View. The tidy
    // moves it, and has to be reachable to do it.
    #expect(source.contains("NSApplicationDelegateAdaptor(MenuBarTidy.self)"))
}

/// The About panel is the app menu's, not the Help menu's, and it should say
/// who owns the software — without this key macOS shows only a name and a
/// version number.
@Test func theBundleDeclaresItsCopyrightForTheAboutPanel() throws {
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Resources/Info.plist")
    let contents = try String(contentsOf: plist, encoding: .utf8)

    #expect(contents.contains("NSHumanReadableCopyright"))
    #expect(contents.contains("SUL-1.0"), "the About panel should name the license")
}
