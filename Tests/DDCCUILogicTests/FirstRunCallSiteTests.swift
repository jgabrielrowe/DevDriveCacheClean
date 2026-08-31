import Testing
import Foundation

/// `FirstRunGateTests` proves the gate remembers the right thing. None of it
/// can see whether a window ever presents the sheet, or whether Quit quits —
/// and a gate nobody shows is worth exactly as much as the clause it was
/// added to evidence, which is to say nothing.
///
/// The same source-text technique `UninstallCallSiteTests` uses, and with the
/// same limits: a match proves a call site exists, not that it renders. That
/// is still strictly more than this suite could otherwise prove, and the
/// failure it guards against — a sheet quietly detached during a refactor —
/// is invisible until a user's first launch, which is the one launch nobody
/// re-runs.

@Test func theWindowPresentsTheFirstRunSheet() throws {
    let text = try sourceText(of: "MainWindow.swift")
    #expect(
        text.contains("FirstRunSheet("),
        "MainWindow never presents FirstRunSheet — the app would open straight into scanning with no terms shown and no record of acceptance.")
    #expect(
        text.contains("needsAcceptance"),
        "MainWindow does not consult FirstRunGate.needsAcceptance — the sheet cannot know whether it has already been answered.")
}

@Test func agreeingRecordsTheAcceptance() throws {
    let text = try sourceText(of: "MainWindow.swift")
    #expect(
        text.contains("FirstRunGate().accept()"),
        "Nothing in MainWindow calls accept() — the sheet would reappear on every launch, and no acceptance would ever be recorded.")
}

/// Declining has to end the session. A Quit button that dismisses into the
/// app makes the question a formality and the record worthless.
@Test func quittingActuallyTerminates() throws {
    let text = try sourceText(of: "MainWindow.swift")
    #expect(
        text.contains("NSApplication.shared.terminate"),
        "MainWindow's onQuit does not terminate — declining the terms would drop the user into the app anyway.")
    // terminate(_:) was observed doing nothing when called from this sheet.
    // It is a request AppKit may decline, so the button needs a floor.
    #expect(
        text.contains("exit(0)"),
        "onQuit has no fallback: if terminate(_:) is declined the Quit button does nothing, which reads to the user as being unable to refuse.")
}

/// Both answers must be reachable, and the sheet must not offer a third way
/// out that records nothing.
@Test func theSheetOffersExactlyTheTwoAnswers() throws {
    let text = try sourceText(of: "FirstRunSheet.swift")
    #expect(text.contains("onQuit()"), "FirstRunSheet has no control wired to onQuit — there is no way to decline.")
    #expect(text.contains("onAgree()"), "FirstRunSheet has no control wired to onAgree — there is no way to accept.")
    #expect(
        text.contains("interactiveDismissDisabled"),
        "FirstRunSheet can be dismissed without answering, which would let a user into the app having neither accepted nor declined.")
}

private func sourceText(of fileName: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // this file -> DDCCUILogicTests
        .deletingLastPathComponent()  // DDCCUILogicTests -> Tests
        .deletingLastPathComponent()  // Tests -> package root
        .appending(path: "Sources/DDCCUI/Views/\(fileName)")
    let text = try String(contentsOf: url, encoding: .utf8)
    try #require(!text.isEmpty, "\(fileName) is empty; this test would prove nothing")
    return text
}
