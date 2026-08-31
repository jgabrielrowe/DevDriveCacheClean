// Tests/DDCCCoreTests/PathGuardTests.swift
import Testing
import Foundation
@testable import DDCCCore

private func context(root: URL, declared: Set<String> = []) -> PathGuard.Context {
    PathGuard.Context(scanRoot: root, declaredPaths: declared)
}

/// Another real account's home directory on this machine, if one exists
/// besides the current user's. Used so the "any child of /Users is
/// protected" rule can be proven against an account we don't control the
/// name of, rather than hardcoding one. Returns nil on a single-account
/// machine, and callers skip gracefully in that case.
private func anotherUsersHome() -> URL? {
    let currentName = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/Users") else {
        return nil
    }
    for name in entries {
        if name == currentName || name == "Shared" || name.hasPrefix(".") { continue }
        var isDirectory: ObjCBool = false
        let path = "/Users/\(name)"
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { continue }
        return URL(fileURLWithPath: path)
    }
    return nil
}

@Test func requiresPrivilegesYieldsLockedInformational() {
    let verdict = PathGuard.evaluate(
        URL(fileURLWithPath: "/Library/Caches"),
        removability: .requiresPrivileges,
        in: context(root: URL(fileURLWithPath: "/Users/someone"))
    )
    #expect(verdict == .lockedInformational)
}

@Test func pathTwoLevelsBelowScanRootIsAllowed() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("code/project/node_modules")
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .allowed)
    }
}

@Test func pathOneLevelBelowScanRootIsRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("Documents")
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path is not at least two levels below the scan root"))
    }
}

@Test func scanRootItselfIsRefused() throws {
    try withTempDirectory { root in
        let verdict = PathGuard.evaluate(root, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path is not at least two levels below the scan root"))
    }
}

/// The two-level rule guards shallow DIRECTORIES — ~/Documents, a project
/// root. A regular file one level down is no more dangerous than the same
/// file two levels down, and refusing it silently hid large files from the
/// Files view whenever the user picked a narrow search root.
@Test func fileOneLevelBelowScanRootIsAllowed() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.file("film.mov", byteCount: 10)
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .allowed)
    }
}

/// A package is one object to macOS and the finder reports it whole, so
/// refusing it for depth alone would contradict the row model.
@Test func packageOneLevelBelowScanRootIsAllowed() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("Old.photoslibrary")
        try tree.file("Old.photoslibrary/database.db", byteCount: 10)
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .allowed)
    }
}

/// The rule still binds plain directories. This is the protection being
/// preserved, and it is what stops the relaxation becoming a hole.
@Test func plainDirectoryOneLevelBelowScanRootIsStillRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("Projects")
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path is not at least two levels below the scan root"))
    }
}

/// Scoping the depth rule to plain directories changed which rule catches this:
/// a file one level outside the scan root now reaches the containment check
/// rather than the depth check. Same verdict, different reason — and the reason
/// is what a future change would break silently.
@Test func aShallowFileOutsideTheScanRootIsRefusedForBeingOutsideIt() throws {
    try withTempDirectory { root in
        let scanRoot = root.appending(path: "scan", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        // Nested one level inside a SIBLING directory, deliberately. A file
        // placed directly in `root` is at the same component depth as
        // `scanRoot`, so `PathGuard.evaluate`'s first, unconditional depth
        // guard refuses it for being too shallow and returns before the
        // containment check ever runs —
        // the test would then pass or fail for the wrong reason and would not
        // pin containment at all.
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let stray = elsewhere.appending(path: "stray.bin")
        try Data([0]).write(to: stray)

        let verdict = PathGuard.evaluate(
            stray, removability: .removable,
            in: PathGuard.Context(scanRoot: scanRoot, declaredPaths: []))

        #expect(verdict == .refused(reason: "path is outside the scan root"))
    }
}

/// The scan root is never a candidate even when it is not a plain
/// directory. Scoping the depth rule to plain directories let a package
/// scan root skip the check and evaluate as allowed against itself.
@Test func packageScanRootItselfIsStillRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("Shoot.photoslibrary")
        try tree.file("Shoot.photoslibrary/database.db", byteCount: 10)
        let verdict = PathGuard.evaluate(
            library, removability: .removable, in: context(root: library))
        #expect(verdict == .refused(reason: "path is not at least two levels below the scan root"))
    }
}

@Test func declaredPathIsAllowedEvenWhenShallow() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("Caches")
        let verdict = PathGuard.evaluate(
            target,
            removability: .removable,
            in: context(root: root, declared: [target.standardizedFileURL.path])
        )
        #expect(verdict == .allowed)
    }
}

@Test(arguments: [
    "/", "/System", "/Library", "/usr", "/bin", "/sbin",
    "/etc", "/var", "/private", "/opt", "/Applications", "/Users", "/Volumes",
    "/tmp", "/cores", "/Network", "/dev",
])
func forbiddenSystemRootsAreRefused(path: String) {
    let verdict = PathGuard.evaluate(
        URL(fileURLWithPath: path),
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/"))
    )
    // On a real macOS filesystem, /etc, /var, and /tmp are themselves
    // symlinks into /private. The leaf-symlink check runs before the
    // protected-system-path check (deliberately — see PathGuard.swift), so
    // those three are refused as symlinks rather than as protected
    // directories. This is benign: their resolved forms normalize back to
    // the same forbidden paths and would refuse there too, so it is not
    // restructured away — every other entry here is refused as a protected
    // system directory directly.
    let symlinkedForbiddenRoots: Set<String> = ["/etc", "/var", "/tmp"]
    let expectedReason = symlinkedForbiddenRoots.contains(path)
        ? "path is a symbolic link"
        : "path is a protected system directory"
    #expect(verdict == .refused(reason: expectedReason))
}

@Test func homeDirectoryItselfIsRefused() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let verdict = PathGuard.evaluate(home, removability: .removable, in: context(root: home))
    #expect(verdict == .refused(reason: "path is the home directory"))
}

@Test(arguments: [
    "Documents", "Desktop", "Downloads", "Pictures",
    "Music", "Movies", "Library", "Applications", "Public",
])
func standardHomeChildrenAreRefused(name: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let verdict = PathGuard.evaluate(
        home.appending(path: name, directoryHint: .isDirectory),
        removability: .removable,
        in: context(root: home)
    )
    #expect(verdict == .refused(reason: "path is a standard home directory"))
}

@Test func symlinkIsRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let real = try tree.directory("code/project/node_modules")
        let link = try tree.symlink("code/project/link_to_modules", to: real)
        let verdict = PathGuard.evaluate(link, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path is a symbolic link"))
    }
}

@Test func symlinkEscapingScanRootIsRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let inside = try tree.directory("inside/deep/dir")
        let link = try tree.symlink("inside/deep/escape", to: URL(fileURLWithPath: "/etc"))
        _ = inside
        let verdict = PathGuard.evaluate(link, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path is a symbolic link"))
    }
}

@Test func parentTraversalIsRefused() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        _ = try tree.directory("a/b/c")
        let sneaky = root.appendingPathComponent("a/b/c/../../../../etc")
        let verdict = PathGuard.evaluate(sneaky, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path contains a parent-directory traversal"))
    }
}

@Test func relativePathIsRefused() {
    // `URL(fileURLWithPath:)` always bakes in an absolute path at
    // construction time (it prepends the current working directory when the
    // string isn't already absolute), so no string passed through that
    // initializer can ever reach `evaluate` still relative — a genuinely
    // reachable non-absolute input has to be built a different way.
    //
    // A `file:` URL constructed directly from a bare scheme, with no path
    // component at all, is such an input: `standardizedFileURL` reduces it
    // to an empty path, which fails `path.hasPrefix("/")`. Verified
    // reachable by mutation: replacing the "not absolute" branch's body with
    // `fatalError()` crashes on exactly this input, so the rule is live, not
    // dead code guarding against nothing.
    let verdict = PathGuard.evaluate(
        URL(string: "file:")!,
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/tmp"))
    )
    #expect(verdict == .refused(reason: "path is not absolute"))
}

@Test func pathOutsideScanRootIsRefused() throws {
    // The target must actually exist and be owned by the current user, or
    // `isRootOwned`'s fail-closed-on-unreadable branch fires first and masks
    // the containment rule this test is meant to pin. Two independent temp
    // directories give a real, non-root-owned path that is still outside
    // `root`'s tree.
    try withTempDirectory { root in
        try withTempDirectory { outside in
            let target = outside.appendingPathComponent("somewhere/else/entirely")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
            #expect(verdict == .refused(reason: "path is outside the scan root"))
        }
    }
}

@Test func volumeRootIsRefused() {
    let verdict = PathGuard.evaluate(
        URL(fileURLWithPath: "/Volumes/External"),
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/Volumes"))
    )
    #expect(verdict == .refused(reason: "path is a volume root"))
}

@Test func refusalCarriesAReason() throws {
    try withTempDirectory { root in
        let verdict = PathGuard.evaluate(root, removability: .removable, in: context(root: root))
        guard case .refused(let reason) = verdict else {
            Issue.record("expected refusal, got \(verdict)")
            return
        }
        #expect(reason.isEmpty == false)
    }
}

// MARK: - additions

/// CRITICAL-1: a symlink partway down the path (not the leaf) must not be
/// usable to reach outside the rules. `homelink` here is an ancestor, not the
/// evaluated path itself, so the leaf-symlink check cannot catch it — only
/// resolving the ancestor chain and re-applying the rules to where it truly
/// points (the real home's Documents) does.
@Test func symlinkedAncestorCannotEscapeTheGuard() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        _ = try tree.directory("a/b")
        let homelink = try tree.symlink("a/b/homelink", to: FileManager.default.homeDirectoryForCurrentUser)
        let escape = homelink.appendingPathComponent("Documents")
        let verdict = PathGuard.evaluate(escape, removability: .removable, in: context(root: root))
        // Refused specifically because it resolves to the real ~/Documents,
        // not merely refused for some unrelated reason.
        #expect(verdict == .refused(reason: "path is a standard home directory"))
    }
}

/// IMPORTANT-2: with `scanRoot: home`, the depth rule alone would already
/// refuse the home directory, masking whether the dedicated home-directory
/// rule does anything. `scanRoot: /` removes that backstop — the depth rule
/// would allow a path this shallow under "/" — so only the home rule itself
/// can be the reason this refuses.
@Test func homeDirectoryIsRefusedEvenWhenScanRootWouldOtherwisePermit() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let verdict = PathGuard.evaluate(
        home,
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/"))
    )
    #expect(verdict == .refused(reason: "path is the home directory"))
}

/// Same masking concern as above, for a standard home child.
@Test func standardHomeChildIsRefusedEvenWhenScanRootWouldOtherwisePermit() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let verdict = PathGuard.evaluate(
        home.appending(path: "Documents", directoryHint: .isDirectory),
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/"))
    )
    #expect(verdict == .refused(reason: "path is a standard home directory"))
}

/// CRITICAL-2: the home-directory rules must protect every account under
/// /Users, not only the one running this process. `scanRoot: /` again
/// removes the depth-rule backstop, so only the generalized rule can be the
/// reason this refuses. Skips gracefully on a single-account machine.
@Test func anotherUsersHomeDirectoryIsRefused() {
    guard let otherHome = anotherUsersHome() else { return }
    let verdict = PathGuard.evaluate(
        otherHome,
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/"))
    )
    #expect(verdict == .refused(reason: "path is a user's home directory"))
}

/// CRITICAL-2, for a standard child of another user's home.
@Test func anotherUsersStandardHomeChildIsRefused() {
    guard let otherHome = anotherUsersHome() else { return }
    let verdict = PathGuard.evaluate(
        otherHome.appending(path: "Library", directoryHint: .isDirectory),
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/"))
    )
    #expect(verdict == .refused(reason: "path is another user's standard home directory"))
}

/// IMPORTANT-0: a non-file URL must be refused before any path-string logic
/// runs, rather than relying on `FileManager.removeItem` to reject the
/// scheme downstream.
@Test func nonFileURLIsRefused() {
    let verdict = PathGuard.evaluate(
        URL(string: "https://evil.example.com/Users/me/Documents")!,
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/"))
    )
    #expect(verdict == .refused(reason: "path is not a file URL"))
}

/// IMPORTANT-1: `declaredPaths` members must be normalized the same way the
/// candidate path is, or a declared path built from the trailing-slash-
/// preserving `path(percentEncoded:)` API (as opposed to the legacy `.path`
/// used in `declaredPathIsAllowedEvenWhenShallow`) would silently fail to
/// match.
@Test func declaredPathMatchesRegardlessOfTrailingSlash() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("Caches")
        let declaredWithTrailingSlash = target.standardizedFileURL.path(percentEncoded: false)
        #expect(declaredWithTrailingSlash.hasSuffix("/"))
        let verdict = PathGuard.evaluate(
            target,
            removability: .removable,
            in: context(root: root, declared: [declaredWithTrailingSlash])
        )
        #expect(verdict == .allowed)
    }
}

// MARK: - Candidate/PathGuard normalization agreement (non-existent paths)
//
// Earlier versions of these tests used real fixture directories and all still
// passed with the trailing-slash strip deleted: for an existing path,
// Foundation consults the filesystem and reconciles spellings before the strip
// runs, so the strip was dead code for them.
//
// For a path that does not exist there is nothing to consult, so a
// directory-hinted and a plain spelling of the same path diverge unless the
// strip reconciles them. Every test below uses a path verified not to exist.

/// Pins that `PathGuard.Context`'s own normalization pipeline (private
/// `normalizedPathString`, exercised through the public `declaredPaths`
/// property) reconciles a directory-hinted and a plain spelling of the same
/// non-existent path into the identical key — and that the key matches
/// `Candidate.normalizedPathKey(for:)`'s output for the same path. Verified
/// by mutation: deleting the strip made `hintedContext.declaredPaths` retain
/// a trailing slash while `plainContext.declaredPaths` did not, so the two
/// sets — and each against `expectedKey` — stopped being equal.
@Test func nonExistentDeclaredPathContextAgreesRegardlessOfSpelling() {
    let base = "/tmp/drive-clean-does-not-exist-\(UUID().uuidString)/sub"
    precondition(!FileManager.default.fileExists(atPath: base), "test fixture must not exist")
    let hintedRaw = base + "/"
    let plainRaw = base

    let hintedContext = context(root: URL(fileURLWithPath: "/tmp"), declared: [hintedRaw])
    let plainContext = context(root: URL(fileURLWithPath: "/tmp"), declared: [plainRaw])
    let expectedKey = Candidate.normalizedPathKey(for: URL(fileURLWithPath: base))

    #expect(hintedContext.declaredPaths == [expectedKey])
    #expect(plainContext.declaredPaths == [expectedKey])
    #expect(hintedContext.declaredPaths == plainContext.declaredPaths)
}

/// Same property as above, but the raw declared string carries a parent-
/// traversal (`..`) component in addition to the trailing slash — the other
/// spelling that has previously defeated this normalization. `Context.init`
/// never rejects `..` in a declared path (only `evaluate`'s top-level
/// candidate check does that, and only before standardization), so this
/// exercises the shared dot-segment-collapsing-plus-strip pipeline rather
/// than being refused outright. Verified by mutation: deleting the strip
/// left a trailing slash on the collapsed form, so it stopped matching
/// `expectedKey`.
@Test func nonExistentDeclaredPathWithParentTraversalAndTrailingSlashAgrees() {
    let uid = UUID().uuidString
    let projectDir = "/tmp/drive-clean-does-not-exist-\(uid)/project"
    let target = projectDir + "/node_modules"
    precondition(!FileManager.default.fileExists(atPath: target), "test fixture must not exist")
    let withParentTraversalAndSlash = projectDir + "/../project/node_modules/"

    let declaredContext = context(
        root: URL(fileURLWithPath: "/tmp"), declared: [withParentTraversalAndSlash])
    let expectedKey = Candidate.normalizedPathKey(for: URL(fileURLWithPath: target))

    #expect(declaredContext.declaredPaths == [expectedKey])
}

/// Pinned on a rule other than the declared-paths check, because that check is
/// unreachable for a non-existent candidate: root ownership runs first and
/// refuses anything whose attributes cannot be read, masking a declared-paths
/// mismatch.
///
/// The "another user's home directory" rule runs before it, and its
/// `parentPath == usersDirectoryPath` comparison is the string equality the
/// strip protects: for a non-existent child of `/Users` the parent carries a
/// trailing slash Foundation cannot rule out, so without the strip the rule
/// silently fails to fire and the verdict falls through to root ownership.
@Test func nonExistentUsersChildIsRefusedAsAnotherUsersHomeDirectory() {
    let fakeUserPath = "/Users/drive-clean-does-not-exist-\(UUID().uuidString)"
    precondition(!FileManager.default.fileExists(atPath: fakeUserPath), "test fixture must not exist")
    let candidate = URL(fileURLWithPath: fakeUserPath, isDirectory: true)

    #expect(Candidate.normalizedPathKey(for: candidate) == fakeUserPath)

    let verdict = PathGuard.evaluate(
        candidate,
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/tmp"))
    )
    #expect(verdict == .refused(reason: "path is a user's home directory"))
}

// MARK: - Absence, distinguished from unreadability
//
// Found by driving the shipped app: three paths appeared under "Refused by
// the Safety Check", above the sentence saying the app owns more than is
// offered. None was on disk. They came from a cask's `zap` stanza — paths
// Homebrew *would* remove, most of which a given machine never has — and the
// root-ownership check refused each as "owned by root", because reading
// attributes throws for a path that is not there.
//
// The refusal is correct and stays: nothing absent should be deletable. What
// was wrong is that it was indistinguishable from a real root-owned refusal, so
// absence was disclosed as territory the app owns. That over-reports.

@Test func nonExistentPathUnderAReadableParentIsRefusedAsAbsent() throws {
    try withTempDirectory { root in
        let target = root.appendingPathComponent("code/project/never-created")
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: PathGuard.doesNotExistReason))
    }
}

/// The nearest existing ancestor is the one that can answer. `fileExists`
/// is false both for a path that is genuinely absent and for one this
/// process may not look at, and those are different facts: the first is a
/// phantom to drop, the second is a real gap to keep disclosing. Brave's
/// own case needs the walk — `Caches/BraveSoftware/Brave-Browser` was
/// absent because `BraveSoftware` itself was absent, so the immediate
/// parent could not answer either.
@Test func nonExistentPathUnderAnUnreadableAncestorStaysRefusedAsUnreadable() throws {
    try withTempDirectory { root in
        let sealed = root.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path)
        }

        let target = sealed.appendingPathComponent("gone/deeper")
        let verdict = PathGuard.evaluate(target, removability: .removable, in: context(root: root))
        #expect(verdict == .refused(reason: "path is owned by root"))
    }
}

/// The fail-closed branch still does its own job. Without this, deleting
/// the absence check's `fileExists` guard entirely would leave both of the
/// tests above passing on a codebase that refuses everything as absent.
@Test func existingRootOwnedPathIsStillRefusedAsRootOwned() {
    let verdict = PathGuard.evaluate(
        URL(fileURLWithPath: "/usr/local"),
        removability: .removable,
        in: context(root: URL(fileURLWithPath: "/usr"))
    )
    #expect(verdict == .refused(reason: "path is owned by root"))
}
