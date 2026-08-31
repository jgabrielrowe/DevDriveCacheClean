import Testing
import Foundation
@testable import DDCCCore

/// Paths that live inside application-support directories, are large, and look
/// like caches by location — but are user data. Measured on the development
/// machine.
///
/// If a future pattern targets any of these, this test fails. That is the point:
/// orphan detection was removed precisely because it offered ~10 GB of live
/// application data for deletion, and the fix must not be re-litigated by
/// accident.
private let userDataFragments: [String] = [
    "User/globalStorage",
    "User/History",
    ".codex/sessions",
    ".codex/state",
    ".codex/plugins",
    ".claude/projects",
    ".claude/file-history",
    ".claude/backups",
    "Godot/app_userdata",
    "Claude Extensions",
    "local-agent-mode-sessions",
    "Claude/Local Storage",
    "Claude/IndexedDB",
    "claude-code-vm",
    // An Unreal project's autosaved levels. They sit two directories from
    // Intermediate and DerivedDataCache, which ARE swept, and a level
    // recovered from an autosave is often the only copy of an hour's work.
    "Saved/Autosaves",
    // The project's actual assets -- everything imported from the store ends
    // up here, and it is the reason the 21 GB vault cache is disposable.
    "Unreal Projects",
    // The machine's Unity activation, one directory above the asset cache
    // that IS swept. Losing it leaves the editor unactivated.
    "Unity/licenses",
]

/// The same known user-data locations as `userDataFragments`, but expressed as
/// full `~`-rooted paths rather than substrings. A substring match (above)
/// only catches a pattern that spells one of these out verbatim. It does
/// nothing for the far more realistic mistake: a pattern that enumerates a
/// PARENT directory one or more levels above one of these — e.g.
/// `.subdirs(of: "~/.claude", tier: .safe)`, which never mentions "projects"
/// but would sweep it in anyway. `noPatternCapturesAKnownUserDataPathDirectlyOrIndirectly`
/// below catches that shape by comparing actual path ancestry rather than
/// substrings.
private let deniedUserDataPaths: [String] = [
    "~/Library/Application Support/Code/User/globalStorage",
    "~/Library/Application Support/Code/User/History",
    "~/.codex/sessions",
    "~/.codex/state_5.sqlite",
    "~/.codex/plugins",
    "~/.claude/projects",
    "~/.claude/file-history",
    "~/.claude/backups",
    "~/Library/Application Support/Godot/app_userdata",
    "~/Library/Application Support/Claude/Claude Extensions",
    "~/Library/Application Support/Claude/local-agent-mode-sessions",
    "~/Library/Application Support/Claude/Local Storage",
    "~/Library/Application Support/Claude/IndexedDB",
    "~/Library/Application Support/Claude/claude-code-vm",
    "~/Documents/Unreal Projects/MyProject/Content",
    "~/Documents/Unreal Projects/MyProject/Saved/Autosaves",
    "~/Library/Unity/licenses",
    "~/Documents/My project/Assets",
    "~/Documents/My project/UserSettings",
    "~/Library/WebKit/com.apple.Safari",
    "~/Library/Cookies/com.apple.Safari.binarycookies",
]

/// Every raw path string any pattern in the table refers to — the literal
/// path it either targets directly (`.absolutePath`) or reaches via
/// enumeration (`.subdirectories`, `.childSubpath`, folded down to the one
/// concrete path each such pattern is anchored on: the parent for
/// `.subdirectories`, since it sweeps everything underneath; parent + subpath
/// for `.childSubpath`, since that is the one fixed location it reaches
/// inside each enumerated child, not the enumeration itself).
///
/// Exhaustive over every `Pattern.Kind` case, deliberately with no
/// `default:`, per the note below: a future kind must be forced through this
/// guard rather than silently skipped.
private var allReferencedPaths: [String] {
    ScanProfile.all.flatMap { profile in
        profile.patterns.compactMap { pattern -> String? in
            switch pattern.kind {
            case .absolutePath(let p): return p
            case .subdirectories(let parent, _): return parent
            case .engineVersions(let parent, _, _): return parent
            case .toolchainVersions(let parent, _, _, _): return parent
            case .childSubpath(let parent, let sub, _): return parent + "/" + sub
            case .directoryName: return nil
            }
        }
    }
}

/// Expands and standardizes a raw `~`-rooted (or absolute) path the same way
/// `ScanProfile.declaredAbsolutePaths` does, so ancestry comparisons below
/// operate on canonical strings rather than reimplementing that
/// normalization here. `Candidate.normalizedPathKey(for:)` is the single
/// place in this project that decides what a path looks like as a comparison
/// key (trailing-slash and standardization ambiguity bit this project three
/// times already — see its doc comment); reusing it instead of hand-rolling
/// a second trim is deliberate.
private func canonical(_ rawPath: String) -> String {
    Candidate.normalizedPathKey(
        for: URL(fileURLWithPath: ScanProfile.expand(rawPath), isDirectory: false)
    )
}

/// True when `reachedPath` — the one concrete location a pattern targets or
/// enumerates from (see `allReferencedPaths`) — is the same as, an ancestor
/// of, or a descendant of `deniedPath`. Any of the three means the pattern
/// can produce or sweep in a known user-data path:
///
/// - equal: the pattern targets the user-data path directly.
/// - `reachedPath` is an ancestor of `deniedPath`: an enumeration pattern
///   (`.subdirectories`/`.childSubpath`) rooted above the denied path would
///   walk straight into it, e.g. `.subdirs(of: "~/.claude", ...)` versus
///   denied `~/.claude/projects`.
/// - `reachedPath` is a descendant of `deniedPath`: the pattern reaches
///   somewhere already inside a directory that is itself entirely user data,
///   e.g. a pattern targeting `~/.codex/sessions/foo` under denied
///   `~/.codex/sessions`.
///
/// Comparisons are separator-aware (a "/" is appended before the prefix
/// check) so `~/.claude` does not appear to contain `~/.claudeX`.
private func captures(reachedPath: String, deniedPath: String) -> Bool {
    let reached = canonical(reachedPath)
    let denied = canonical(deniedPath)
    if reached == denied { return true }
    if denied.hasPrefix(reached + "/") { return true }
    if reached.hasPrefix(denied + "/") { return true }
    return false
}

@Test func noPatternTargetsAKnownUserDataPath() {
    for referenced in allReferencedPaths {
        for fragment in userDataFragments {
            #expect(
                referenced.contains(fragment) == false,
                "pattern \"\(referenced)\" targets known user data \"\(fragment)\""
            )
        }
    }
}

/// The critical guard: not just "does a pattern spell out a denied path
/// verbatim" (covered above) but "does a pattern's actual reach — as an
/// enumeration root, a child-subpath anchor, or a direct target — overlap a
/// denied path at all, in either direction." A pattern one directory above a
/// denied path is just as unsafe as one that names it outright; nobody adds
/// `~/.claude/projects` by hand, they add `~/.claude` as a sweep and never
/// look inside it.
///
/// `.childPath(in: "~/Library/Containers", subpath: "Data/Library/Caches", ...)`
/// is the case this must NOT flag: Containers holds user data generally, but
/// this pattern's one fixed reach is
/// `~/Library/Containers/Data/Library/Caches` (per-child wildcard folded out,
/// same as `allReferencedPaths` does), which is neither equal to, an
/// ancestor of, nor a descendant of any denied path. `~/Library/Containers`
/// itself is deliberately absent from `deniedUserDataPaths` — comparing the
/// pattern's full reached location rather than the bare parent is what keeps
/// this legitimate, narrowly-scoped pattern from tripping the guard.
@Test func noPatternCapturesAKnownUserDataPathDirectlyOrIndirectly() {
    for referenced in allReferencedPaths {
        for denied in deniedUserDataPaths {
            #expect(
                captures(reachedPath: referenced, deniedPath: denied) == false,
                "pattern \"\(referenced)\" captures known user data \"\(denied)\" (directly, or by enumerating an ancestor, or by reaching a descendant)"
            )
        }
    }
}

@Test func denylistsAreNonEmpty() {
    // Guards against someone emptying either list to make the tests above
    // pass vacuously.
    #expect(userDataFragments.count >= 14)
    #expect(deniedUserDataPaths.count >= 14)
}
