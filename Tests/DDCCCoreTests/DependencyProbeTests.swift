import Testing
import Foundation
@testable import DDCCCore

/// The only signal in this design that proves something DEAD rather than
/// merely unclaimed. Measured: a native messaging manifest
/// declares the executable it launches, and com.openai.codexextension's
/// target no longer exists — it can never work again.
@Test func aManifestWhoseTargetIsMissingIsDead() throws {
    try withTempDirectory { dir in
        let tree = FixtureTree(root: dir)
        let missingTarget = dir.appending(path: "codex/codex-native-host", directoryHint: .notDirectory)
        let manifest = try tree.file(
            "manifest.json",
            byteCount: 0)
        try """
        { "name": "com.openai.codexextension", "path": "\(missingTarget.path)", "type": "stdio" }
        """.data(using: .utf8)!.write(to: manifest)

        let state = DependencyProbe.classify(manifestAt: manifest)
        #expect(state == .dead(target: missingTarget.path))
    }
}

@Test func aManifestWhoseTargetExistsIsLive() throws {
    try withTempDirectory { dir in
        let tree = FixtureTree(root: dir)
        let target = try tree.file("claude/chrome-native-host", byteCount: 4)
        let manifest = try tree.file("manifest.json", byteCount: 0)
        try """
        { "name": "com.anthropic.claude_code_browser_extension", "path": "\(target.path)", "type": "stdio" }
        """.data(using: .utf8)!.write(to: manifest)

        let state = DependencyProbe.classify(manifestAt: manifest)
        #expect(state == .live(target: target.path))
    }
}

/// The caveat a crude test gets wrong. com.epicgames.launcher.plist has
/// Program = "open", a bare command resolved via PATH, not a broken
/// pointer. The rule is ABSOLUTE paths that do not exist; a bare command is
/// unknown, never dead. Getting this wrong offers a live launch agent for
/// deletion.
@Test func aLaunchAgentWithABareCommandIsUnknownNotDead() throws {
    try withTempDirectory { dir in
        let tree = FixtureTree(root: dir)
        let plistURL = tree.root.appending(path: "com.epicgames.launcher.plist", directoryHint: .notDirectory)
        let plist: [String: Any] = [
            "Label": "com.epicgames.launcher",
            "Program": "open",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        let state = DependencyProbe.classify(launchAgentAt: plistURL)
        guard case .unknown = state else {
            Issue.record("expected .unknown for bare command, got \(state)")
            return
        }
    }
}

/// Measured on the development machine: com.adobe.GC.Invoker-1.0.plist
/// points at an absolute path under /Library that is gone — Adobe's
/// integrity agent, still firing, serving software that was removed.
@Test func aLaunchAgentWithAMissingAbsoluteProgramIsDead() throws {
    try withTempDirectory { dir in
        let tree = FixtureTree(root: dir)
        let plistURL = tree.root.appending(
            path: "com.adobe.GC.Invoker-1.0.plist", directoryHint: .notDirectory)
        let missingTarget = "/Library/Application Support/Adobe/AdobeGCClient/agcinvokerutility"
        let plist: [String: Any] = [
            "Label": "com.adobe.GC.Invoker-1.0",
            "ProgramArguments": [missingTarget, "--gone"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        let state = DependencyProbe.classify(launchAgentAt: plistURL)
        #expect(state == .dead(target: missingTarget))
    }
}

@Test func aLaunchAgentWithNeitherProgramNorArgumentsIsUnknown() throws {
    try withTempDirectory { dir in
        let tree = FixtureTree(root: dir)
        let plistURL = tree.root.appending(path: "com.example.empty.plist", directoryHint: .notDirectory)
        let plist: [String: Any] = [
            "Label": "com.example.empty"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        let state = DependencyProbe.classify(launchAgentAt: plistURL)
        guard case .unknown = state else {
            Issue.record("expected .unknown for missing Program/ProgramArguments, got \(state)")
            return
        }
    }
}

// MARK: - Launch agents that shell out through `open`
//
// The real plist, from this machine after Epic Games Launcher was removed:
//
//   ProgramArguments = ["open", "/Applications/Epic Games Launcher.app",
//                       "--args", "-silent", "-launchcontext=boot"]
//
// argv[0] is `open`, a bare command, so the target rule looked at it, said
// "resolved via PATH" and returned .unknown. The agent survived the uninstall
// and goes on asking macOS to launch a deleted app at every login, and nothing
// in the interface said so.
//
// The rule does not change: only an absolute path that does not exist is dead.
// What changes is WHICH argument it is applied to.

private func agentPlist(_ arguments: [String], at url: URL) throws {
    let plist = try PropertyListSerialization.data(
        fromPropertyList: ["Label": "test", "ProgramArguments": arguments],
        format: .xml, options: 0)
    try plist.write(to: url)
}

@Test func anOpenAgentIsJudgedByTheBundleItOpensNotByOpenItself() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let plist = root.appending(path: "agent.plist")
        _ = try tree.directory("Applications")
        try agentPlist(
            ["open", root.appending(path: "Applications/Gone.app")
                .path(percentEncoded: false),
             "--args", "-silent"],
            at: plist)

        guard case .dead(let target) = DependencyProbe.classify(launchAgentAt: plist) else {
            Issue.record("an open target that does not exist must read as dead")
            return
        }
        #expect(target.hasSuffix("Gone.app"))
    }
}

/// The safety half, and the case the original comment was protecting: an agent
/// whose bundle is still installed must stay live, not become deletable.
@Test func anOpenAgentWhoseBundleExistsIsLive() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let app = try tree.directory("Applications/Here.app")
        let plist = root.appending(path: "agent.plist")
        try agentPlist(
            ["open", app.path(percentEncoded: false), "--args", "-silent"], at: plist)

        guard case .live = DependencyProbe.classify(launchAgentAt: plist) else {
            Issue.record("an open target that exists must read as live")
            return
        }
    }
}

/// `open <path> --args <args for the opened app>`. Everything after `--args`
/// belongs to the application being launched, not to `open`, so a path-looking
/// argument there names nothing this probe can judge.
@Test func argumentsAfterTheArgsDelimiterAreNotTheTarget() throws {
    try withTempDirectory { root in
        let plist = root.appending(path: "agent.plist")
        try agentPlist(["open", "--args", "/nonexistent/not-the-target"], at: plist)

        guard case .unknown = DependencyProbe.classify(launchAgentAt: plist) else {
            Issue.record("a path after --args must not be treated as open's target")
            return
        }
    }
}

/// An `open` invocation naming no absolute path stays unknown, as any bare
/// command does. Nothing here relaxes the rule for a target it cannot see.
@Test func anOpenAgentWithNoAbsolutePathIsStillUnknown() throws {
    try withTempDirectory { root in
        let plist = root.appending(path: "agent.plist")
        try agentPlist(["open", "-a", "Safari"], at: plist)

        guard case .unknown = DependencyProbe.classify(launchAgentAt: plist) else {
            Issue.record("open with no absolute path must stay unknown")
            return
        }
    }
}
