import Testing
import Foundation
@testable import DDCCCore

/// Found by running the real sweep on a live machine, where Codex appeared
/// three times and every Parallels Toolbox tool was listed as its own
/// uninstall.
///
/// **161 of 425 discovered "apps" were nested inside another `.app`** — 134
/// of them non-Apple. `InstalledApps.scan` walks four levels deep so it can
/// find Unity's editors, and that walk descends *into* bundles:
/// `Parallels Toolbox.app/Contents/Applications/Airplane Mode.app`,
/// `Claude.app/Contents/Frameworks/Claude Helper (GPU).app`,
/// `Firefox.app/Contents/MacOS/crashreporter.app`.
///
/// Invisible until bundle removal shipped an hour earlier: a helper has no
/// leftovers of its own, so it measured zero and the list dropped it. Once
/// the bundle itself became an item, every helper acquired a size and a row.
///
/// It is not only noise. **A nested helper's bytes are already counted inside
/// its parent's bundle**, so offering both double-counts — and the sidebar
/// total cannot catch it by deduping paths, because a helper's path is a
/// descendant of its parent's, not the same string.

@Test func aBundleInsideAnotherBundleIsNotASeparateInstall() {
    #expect(InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Parallels Toolbox.app/Contents/Applications/Alarm.app")))
    #expect(InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (GPU).app")))
    #expect(InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Instruments.app")))
}

/// The other half, and the one a careless prefix check gets wrong: a
/// top-level app is not nested just because its own name ends in `.app`.
@Test func aTopLevelBundleIsNotNested() {
    #expect(!InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Brave Browser.app")))
    #expect(!InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Users/someone/Applications/Thing.app")))
    // A directory merely *named* like a bundle, containing an app. Nesting is
    // about a real enclosing bundle, and this ancestor is not one — but the
    // check is lexical, so this documents what it actually does rather than
    // claiming more. Erring toward "nested" here hides a row; erring the
    // other way double-counts. Hiding is the safer direction.
    #expect(InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Users/someone/Archive.app/Backup.app")))
}

/// Trailing slashes must not change the answer. `InstalledApps` builds its
/// URLs from a directory enumeration, which hands back directory-hinted URLs.
@Test func nestingIsUnaffectedByATrailingSlash() {
    #expect(InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Parent.app/Contents/Helper.app", isDirectory: true)))
    #expect(!InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Parent.app", isDirectory: true)))
}

/// Case: macOS filesystems are usually case-insensitive, and a bundle
/// spelled `.APP` is the same kind of thing.
@Test func nestingIgnoresCase() {
    #expect(InstalledApps.isNestedInsideAnotherBundle(
        URL(fileURLWithPath: "/Applications/Parent.APP/Contents/Helper.app")))
}

// MARK: - Applied by the sweep

/// The predicate is worth nothing unless the sweep uses it.
///
/// Injected fixtures rather than a real-machine sweep: both assertions held
/// against this machine's real 425-app population while being written, and
/// each run cost **39 seconds** against a suite that runs in five. This file
/// follows the precedent already set here — a real sweep was trimmed once
/// before for taking 45% of the budget — so the population is a fixture and
/// the finding it came from is recorded above.
private func fixtureApps(in root: URL) throws -> InstalledApps {
    let tree = FixtureTree(root: root)
    let apps = try tree.directory("Applications")

    func bundle(_ relativePath: String, _ bundleID: String) throws {
        let url = try tree.directory("Applications/" + relativePath + "/Contents")
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": (relativePath as NSString).lastPathComponent,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appending(path: "Info.plist", directoryHint: .notDirectory))
    }

    try bundle("Parent.app", "com.example.parent")
    // Exactly the shape that produced "Codex appears three times" and every
    // Parallels Toolbox tool as its own row.
    try bundle("Parent.app/Contents/Applications/Helper.app", "com.example.parent.helper")
    try bundle("Standalone.app", "com.example.standalone")
    try bundle("DDCC.app", "com.jgabrielrowe.devdrivecacheclean")

    return InstalledApps.scan(roots: [apps], maxDepth: 4, launchServices: { _ in false })
}

private func sweep(
    _ apps: InstalledApps, environment: ScanEnvironment, selfBundleID: String
) async -> UninstallReport {
    await UninstallCoordinator(selfBundleID: selfBundleID).run(
        installedApps: { apps }, environment: environment, receipts: { (receipts: [], fullyRead: true) },
        caskIndex: { nil }, caskroomTokens: { [] }, applicationGroups: { _ in [] },
        isRunning: { _ in false }, receiptPaths: { _ in nil })
}

private func listedIDs(_ report: UninstallReport) -> [String] {
    report.rows.compactMap { row in
        guard case .app(let footprint) = row else { return nil }
        return footprint.identity.bundleID
    }
}

@Test func theSweepListsNoNestedBundleAndNotItself() async throws {
    try await withTempDirectory { root in
        let apps = try fixtureApps(in: root)
        // Positive control on the fixture itself: the scan must actually have
        // found the nested helper, or the filter below is filtering nothing.
        #expect(apps.byID["com.example.parent.helper"] != nil)

        let report = await sweep(
            apps, environment: ScanEnvironment(libraryURL: root.appending(path: "Library")),
            selfBundleID: "com.jgabrielrowe.devdrivecacheclean")
        let ids = listedIDs(report)

        #expect(!ids.contains("com.example.parent.helper"), "a nested bundle reached the sweep")
        #expect(!ids.contains("com.jgabrielrowe.devdrivecacheclean"), "DDCC offered to uninstall itself")
        #expect(ids.contains("com.example.parent"))
        #expect(ids.contains("com.example.standalone"))
    }
}

/// A fork changing its bundle identifier — which `TRADEMARKS.md` requires,
/// since macOS keys Full Disk Access to it — must exclude *itself*, not the
/// original. Hardcoding would leave the fork listing itself while hiding a
/// DDCC the user may not even have installed.
@Test func theSelfExclusionFollowsTheRunningBundleID() async throws {
    try await withTempDirectory { root in
        let apps = try fixtureApps(in: root)
        let report = await sweep(
            apps, environment: ScanEnvironment(libraryURL: root.appending(path: "Library")),
            selfBundleID: "com.example.standalone")
        let ids = listedIDs(report)

        #expect(!ids.contains("com.example.standalone"), "the running bundle id was not excluded")
        #expect(ids.contains("com.jgabrielrowe.devdrivecacheclean"),
                "a fork must not hide the original DDCC, only itself")
    }
}
