// Sources/DDCCCore/Uninstall/DependencyProbe.swift
import Foundation

/// The verdict on a single declared dependency: does the executable an
/// artifact names still exist?
public enum DependencyState: Sendable, Equatable {
    /// The declared target is an absolute path, and it exists.
    case live(target: String)
    /// The declared target is an absolute path and does not exist. The only
    /// state offered as proof of death — see `DependencyProbe`.
    case dead(target: String)
    /// Nothing was provable: the file was missing or unparseable, the
    /// declaration absent or the wrong type, or the target was not an absolute
    /// path.
    case unknown(reason: String)
}

/// Classifies an artifact by whether the executable it declares still exists.
///
/// Every other evidence source here answers "who owns this?". This answers "is
/// this provably dead?" — a question none of them can. The reliable signal is a
/// declared dependency that no longer exists, not the absence of a claimant:
/// inferring abandonment from directory names offers live browser profiles and
/// editor settings for deletion. Broken pointers are provable; names are not.
///
/// Two artifact kinds carry such a declaration. A native messaging host
/// manifest is JSON with a `path` key. A LaunchAgent plist names its executable
/// in `Program`, or in the first element of `ProgramArguments` when that key is
/// absent — measured: `com.adobe.GC.Invoker-1.0.plist` still points at an
/// `agcinvokerutility` that is gone.
///
/// Only an absolute path that does not exist is `.dead`. A bare command is
/// `.unknown`, because it resolves against `PATH` at launch and this reader
/// does not resolve `PATH` — see `classify(launchAgentAt:)`. Measured:
/// `com.epicgames.launcher.plist` sets `Program` to `open`, so a naive
/// missing-means-dead check would offer a loaded Epic launch agent for
/// deletion.
///
/// `.dead` is the only verdict in this feature that authorises removal on its
/// own evidence, so every uncertain path resolves to `.unknown`. A wrong
/// `.unknown` costs a deletion the user must approve by hand; a wrong `.dead`
/// costs data.
public enum DependencyProbe {

    /// Classifies a native messaging host manifest by whether the
    /// executable at its `path` key still exists.
    public static func classify(manifestAt url: URL) -> DependencyState {
        guard let data = try? Data(contentsOf: url) else {
            return .unknown(reason: "manifest could not be read")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return .unknown(reason: "manifest is not a JSON object")
        }
        guard let path = dictionary["path"] as? String else {
            return .unknown(reason: "manifest has no string \"path\" key")
        }
        return classify(declaredTarget: path)
    }

    /// Classifies a LaunchAgent plist by whether the executable it names —
    /// `Program`, or failing that the first element of `ProgramArguments`
    /// — still exists.
    ///
    /// A bare command is not resolved against `PATH`. This can run inside a GUI
    /// process, whose `PATH` need not match the one the agent was registered
    /// under — launchd sets its own minimal environment — so a lookup that
    /// failed here would produce `.dead` for a command that works fine under
    /// launchd. `.unknown` costs a skipped classification; a false `.dead`
    /// costs a live agent.
    public static func classify(launchAgentAt url: URL) -> DependencyState {
        guard let data = try? Data(contentsOf: url) else {
            return .unknown(reason: "launch agent plist could not be read")
        }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil),
            let dictionary = object as? [String: Any]
        else {
            return .unknown(reason: "launch agent is not a plist dictionary")
        }

        if let program = dictionary["Program"] as? String {
            return classify(declaredTarget: program)
        }
        if let arguments = dictionary["ProgramArguments"] as? [Any],
           let first = arguments.first as? String {
            // `open` is a launcher, not the target. Epic's agent is literally
            // ["open", "/Applications/Epic Games Launcher.app", "--args",
            // "-silent", ...], so judging argv[0] asks whether /usr/bin/open
            // exists -- which it always does -- and the agent survives the
            // uninstall of the app it exists to start, going on asking macOS
            // to launch a deleted bundle at every login.
            //
            // The rule is unchanged: only an absolute path that does not exist
            // is dead. What changes is which argument it is applied to.
            if let opened = bundleOpened(by: arguments.compactMap { $0 as? String }) {
                return classify(declaredTarget: opened)
            }
            return classify(declaredTarget: first)
        }
        return .unknown(reason: "plist has neither Program nor ProgramArguments")
    }

/// The absolute path an `open` invocation names, if it names one.
    ///
    /// Returns nil for anything else, so a non-`open` agent is judged exactly
    /// as before. `open -a Safari` yields nil too: it names an application by
    /// name rather than by path, and this probe never guesses at a target it
    /// cannot see.
    ///
    /// Scanning stops at `--args`, because `open <path> --args <...>` gives
    /// everything after that delimiter to the application being launched. A
    /// path-shaped string there is an argument to somebody else's program, not
    /// a target this probe may judge.
    private static func bundleOpened(by arguments: [String]) -> String? {
        guard let command = arguments.first else { return nil }
        guard command == "open" || command == "/usr/bin/open" else { return nil }

        for argument in arguments.dropFirst() {
            if argument == "--args" { return nil }
            if argument.hasPrefix("/") { return argument }
        }
        return nil
    }

    /// The rule shared by both artifact kinds once a candidate target
    /// string has been extracted: an absolute path that exists is live, an
    /// absolute path that does not exist is dead, and anything else —
    /// empty, relative, or a bare command resolved via `PATH` — is
    /// unknown. See the type-level doc for why absoluteness, not mere
    /// existence, is the line between provable and unprovable.
    private static func classify(declaredTarget target: String) -> DependencyState {
        guard !target.isEmpty else {
            return .unknown(reason: "declared target is empty")
        }
        guard target.hasPrefix("/") else {
            return .unknown(reason: "bare command, resolved via PATH")
        }
        return FileManager.default.fileExists(atPath: target)
            ? .live(target: target)
            : .dead(target: target)
    }
}
