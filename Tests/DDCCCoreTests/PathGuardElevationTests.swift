import Foundation
import Testing

@testable import DDCCCore

/// `PathGuard.requiresElevation` — the one narrow question the uninstaller may
/// ask about a path the guard has already refused.
///
/// Measured: and the measurement is the whole reason this exists:
/// `FileManager.trashItem` fails on an item the user does not own even when the
/// containing directory is writable, so a pkg-installed app (Word, Excel,
/// Trello) cannot be removed unprivileged. The POSIX argument that a Trash move
/// is "just a rename" holds for `removeItem` and is false for `trashItem`.
///
/// The rule is deliberately not "root ownership is survivable". It is "root
/// ownership is survivable *for a path the caller declared*" — which, at the
/// only call site, is the identity's own `.app` bundle and nothing else. A
/// root-owned path that reaches `.allowed` by any other route must not qualify,
/// or this becomes a general-purpose hole in the guard rather than one door.
@Suite struct PathGuardElevationTests {

    /// Real, root-owned, and present on every macOS. A fixture cannot stand in
    /// here: creating a root-owned file needs privileges the test process does
    /// not have, and the whole point is the ownership.
    private let rootOwned = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private func context(declaring paths: [URL], scanRoot: URL) -> PathGuard.Context {
        PathGuard.Context(
            scanRoot: scanRoot,
            declaredPaths: Set(paths.map { Candidate.normalizedPathKey(for: $0) }))
    }

    @Test func aDeclaredRootOwnedBundleRequiresElevation() {
        let context = context(
            declaring: [rootOwned], scanRoot: rootOwned.deletingLastPathComponent())

        // Precondition: the guard genuinely refuses it today, and refuses it
        // *for ownership*. If this ever stops being the refusal reason, the
        // query below is answering a question nobody asked.
        #expect(
            PathGuard.evaluate(rootOwned, removability: .removable, in: context)
                == .refused(reason: "path is owned by root"))

        #expect(PathGuard.requiresElevation(rootOwned, removability: .removable, in: context))
    }

    /// The containment property. Root ownership buys nothing on its own.
    @Test func anUndeclaredRootOwnedPathDoesNotRequireElevation() {
        let context = context(declaring: [], scanRoot: URL(fileURLWithPath: "/System/Applications"))
        #expect(PathGuard.requiresElevation(rootOwned, removability: .removable, in: context) == false)
    }

    /// A path that is already removable needs no elevation, and must not be
    /// reported as needing it — the caller uses this to pick a removal route.
    @Test func aPathTheGuardAlreadyAllowsDoesNotRequireElevation() throws {
        try withTempDirectory { root in
            let tree = FixtureTree(root: root)
            let bundle = try tree.directory("Applications/Fixture.app")
            let context = context(declaring: [bundle], scanRoot: root)

            #expect(PathGuard.evaluate(bundle, removability: .removable, in: context) == .allowed)
            #expect(
                PathGuard.requiresElevation(bundle, removability: .removable, in: context) == false)
        }
    }

    /// Fail closed on absence, exactly as `evaluate` does. A declared path that
    /// is gone must not be reported as "removable with authentication" — there
    /// would be nothing to authenticate against.
    @Test func anAbsentDeclaredPathDoesNotRequireElevation() throws {
        try withTempDirectory { root in
            let missing = root.appending(path: "Applications/Gone.app", directoryHint: .isDirectory)
            let context = context(declaring: [missing], scanRoot: root)

            #expect(
                PathGuard.requiresElevation(missing, removability: .removable, in: context) == false)
        }
    }

    /// Every other refusal still stands. A symlink is the sharpest case: it is
    /// root-owned *and* declared, and the only thing refusing it is that it is
    /// a symlink — which elevation must not paper over, since authenticating
    /// then following a link is how you delete the wrong thing as root.
    @Test func aDeclaredRootOwnedSymlinkDoesNotRequireElevation() throws {
        let symlink = URL(fileURLWithPath: "/Applications/Safari.app")
        // Precondition: this is the shape the test needs, or it proves nothing.
        let attributes = try? FileManager.default.attributesOfItem(atPath: symlink.path)
        try #require(attributes?[.type] as? FileAttributeType == .typeSymbolicLink)

        let context = context(declaring: [symlink], scanRoot: URL(fileURLWithPath: "/Applications"))
        #expect(PathGuard.requiresElevation(symlink, removability: .removable, in: context) == false)
    }

    /// A display-only row is never removable by any route, authenticated or not.
    @Test func aPrivilegedRowDoesNotRequireElevation() {
        let context = context(
            declaring: [rootOwned], scanRoot: rootOwned.deletingLastPathComponent())
        #expect(
            PathGuard.requiresElevation(rootOwned, removability: .requiresPrivileges, in: context)
                == false)
    }
}
