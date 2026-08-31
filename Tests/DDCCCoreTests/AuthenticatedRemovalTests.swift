import Foundation
import Testing

@testable import DDCCCore

/// Removing an app the user does not own, through an authenticated route.
///
/// The property that matters is that it takes **two** independent keys: the row
/// must claim it needs authentication, and `PathGuard` must independently agree
/// that root ownership is the only thing refusing it. A row that merely asserts
/// the flag gets nothing, which is what stops a selection-UI defect or a stale
/// result from turning into an authenticated removal of something else.
@Suite struct AuthenticatedRemovalTests {

    private struct Row: Deletable {
        let path: URL
        var sizeBytes: Int64 = 100
        var removability: Removability = .removable
        var isDeletable: Bool = true
        var displayName: String = "Fixture"
        var requiresAuthentication: Bool = false
    }

    private struct Spy {
        var trashed: [URL] = []
        var authenticated: [URL] = []
        var removed: [URL] = []
    }

    private func operations(_ spy: UnsafeMutablePointer<Spy>) -> DeletionService.FileOperations {
        DeletionService.FileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            removeItem: { spy.pointee.removed.append($0) },
            trashItem: { spy.pointee.trashed.append($0); return $0 },
            authenticatedTrashItem: { spy.pointee.authenticated.append($0) }
        )
    }

    /// The real shape: a root-owned bundle the identity declares.
    @Test func aRootOwnedDeclaredBundleGoesThroughTheAuthenticatedRoute() {
        let bundle = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let context = PathGuard.Context(
            scanRoot: bundle.deletingLastPathComponent(),
            declaredPaths: [Candidate.normalizedPathKey(for: bundle)])
        var spy = Spy()

        let report = withUnsafeMutablePointer(to: &spy) { pointer in
            DeletionService.delete(
                [Row(path: bundle, requiresAuthentication: true)],
                permanently: false, in: context, fileOperations: operations(pointer))
        }

        #expect(report.isCompleteSuccess)
        #expect(spy.authenticated == [bundle])
        #expect(spy.trashed.isEmpty)
        #expect(spy.removed.isEmpty)
    }

    /// The second key. Asserting the flag on a row the guard refuses for some
    /// *other* reason must change nothing.
    @Test func theFlagAloneDoesNotUnlockARowTheGuardRefusesOnOtherGrounds() {
        // Root-owned and refused, but never declared — so ownership is not the
        // only thing standing in the way.
        let bundle = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let context = PathGuard.Context(
            scanRoot: bundle.deletingLastPathComponent(), declaredPaths: [])
        var spy = Spy()

        let report = withUnsafeMutablePointer(to: &spy) { pointer in
            DeletionService.delete(
                [Row(path: bundle, requiresAuthentication: true)],
                permanently: false, in: context, fileOperations: operations(pointer))
        }

        #expect(report.isCompleteSuccess == false)
        #expect(spy.authenticated.isEmpty)
        #expect(spy.trashed.isEmpty)
        #expect(spy.removed.isEmpty)
    }

    /// Permanent deletion is not offered for these. An unprivileged `rm -rf`
    /// on a root-owned tree fails partway by design (measured: it refuses at
    /// the first root-owned entry), and Finder's authenticated route only ever
    /// moves to the Trash — so there is no honest permanent option to route to.
    @Test func permanentDeletionOfAnAuthenticatedRowIsRefusedRatherThanAttempted() {
        let bundle = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let context = PathGuard.Context(
            scanRoot: bundle.deletingLastPathComponent(),
            declaredPaths: [Candidate.normalizedPathKey(for: bundle)])
        var spy = Spy()

        let report = withUnsafeMutablePointer(to: &spy) { pointer in
            DeletionService.delete(
                [Row(path: bundle, requiresAuthentication: true)],
                permanently: true, in: context, fileOperations: operations(pointer))
        }

        #expect(report.isCompleteSuccess == false)
        #expect(spy.removed.isEmpty)
        #expect(spy.authenticated.isEmpty)
        #expect(report.failed.first?.reason.contains("Trash") == true)
    }

    /// An ordinary row is untouched by any of this.
    @Test func anOrdinaryRowStillTakesThePlainTrashRoute() throws {
        try withTempDirectory { root in
            let tree = FixtureTree(root: root)
            let target = try tree.directory("dev/project/node_modules")
            let context = PathGuard.Context(scanRoot: root, declaredPaths: [])
            var spy = Spy()

            let report = withUnsafeMutablePointer(to: &spy) { pointer in
                DeletionService.delete(
                    [Row(path: target)],
                    permanently: false, in: context, fileOperations: operations(pointer))
            }

            #expect(report.isCompleteSuccess)
            #expect(spy.trashed == [target])
            #expect(spy.authenticated.isEmpty)
        }
    }

    // MARK: - Script construction

    /// A path with a quote in it must not be able to end the AppleScript
    /// literal early and redirect Finder at a different path than the guard
    /// approved.
    @Test func aQuotedPathIsEscapedRatherThanEndingTheLiteral() {
        let script = FinderTrash.script(for: URL(fileURLWithPath: "/Applications/He said \"hi\".app"))
        #expect(script.hasSuffix("\"/Applications/He said \\\"hi\\\".app\""))
    }

    @Test func aBackslashIsEscapedBeforeTheQuoteNotAfter() {
        let script = FinderTrash.script(for: URL(fileURLWithPath: "/Applications/back\\slash.app"))
        #expect(script.contains("/Applications/back\\\\slash.app"))
    }

    @Test func cancellingAuthenticationIsReportedAsCancellation() {
        #expect(
            FinderTrash.failure(forExitCode: 1, stderr: "execution error: User canceled. (-128)")
                == .cancelled)
    }

    @Test func aMissingAutomationPermissionSaysWhereToGrantIt() {
        let failure = FinderTrash.failure(
            forExitCode: 1, stderr: "execution error: Not authorized to send Apple events (-1743)")
        #expect(failure == .automationNotPermitted)
        #expect(failure?.errorDescription?.contains("Automation") == true)
    }

    @Test func aCleanExitIsNotAFailure() {
        #expect(FinderTrash.failure(forExitCode: 0, stderr: "") == nil)
    }
}
