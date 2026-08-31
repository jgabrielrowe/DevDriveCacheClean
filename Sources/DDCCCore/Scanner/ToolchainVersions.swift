import Foundation

/// Which installed toolchain versions are dead weight, and which are still
/// load-bearing.
///
/// A version manager keeps every version ever installed, forever. Measured
/// on this development machine: nine node versions under
/// `~/.nvm/versions/node` totalling roughly 3.6 GB, of which one was in use.
/// The rest are recoverable by a single `nvm install`, which is what makes them
/// `.costly` rather than `.destructive` — real bandwidth, no lost work.
///
/// The whole difficulty is in what must *not* be offered, because deleting the
/// version a shell or a long-running server is on breaks something the user is
/// in the middle of. Three retentions, each measured rather than assumed:
///
/// 1. **The highest installed version.** nvm's own `default` alias on this
///    machine is the literal string `node`, which means "the latest installed"
///    — so the newest is in use even when nothing points at it explicitly.
/// 2. **Whatever the manager points at**, followed through alias chains:
///    `default` → `lts/*` → `lts/krypton` → `v22.22.2` is a real chain here.
/// 3. **Any version with a live process.** Measured: twenty processes were
///    running out of `v24.13.0` while a Homebrew node served one more. This is
///    the same rule the uninstaller applies to a running app, for the same
///    reason — the fact that something is in use right now outranks every
///    inference about what ought to be in use.
public enum ToolchainVersions {

    /// Versions that may be offered: everything installed, minus the retained.
    ///
    /// Order follows `versions`, so the caller's enumeration order survives.
    public static func stale(
        among versions: [URL],
        pointer: String?,
        resolveAlias: (String) -> String?,
        runningExecutables: [URL]?
    ) -> [URL] {
        let retained = retained(
            among: versions, pointer: pointer, resolveAlias: resolveAlias,
            runningExecutables: runningExecutables)
        return versions.filter { !retained.contains($0.lastPathComponent) }
    }

    /// The version names that must never be offered. Exposed so a caller can
    /// say *why* a version is absent rather than silently omitting it.
    public static func retained(
        among versions: [URL],
        pointer: String?,
        resolveAlias: (String) -> String?,
        runningExecutables: [URL]?
    ) -> Set<String> {
        let names = versions.map(\.lastPathComponent)
        guard names.isEmpty == false else { return [] }

        // `nil` is "the process list could not be enumerated", which is not
        // the same fact as "nothing is running out of these" — and
        // `proc_listpids` hands back the same empty array for both. Rule 3 is
        // the one the other two defer to, because a version something is
        // running out of is in use whatever an alias claims; skipping it
        // silently offers every version but the newest and the pointer's
        // target while a dev server is live inside one.
        //
        // So everything is retained and nothing is offered. That is the
        // direction this feature can afford to be wrong in: the cost is a
        // sweep that finds no toolchain versions, against deleting the
        // interpreter a running process is executing.
        guard let runningExecutables else { return Set(names) }

        var retained: Set<String> = []

        // 1. The newest, always.
        if let highest = highest(of: names) { retained.insert(highest) }

        // 2. Whatever the manager points at, alias chains followed.
        if let pointer, let target = resolve(pointer, in: names, resolveAlias: resolveAlias) {
            retained.insert(target)
        }

        // 3. Anything with a live process. Compared on path components rather
        //    than string prefixes: `.../v20.1` must not match `.../v20.10`.
        for version in versions {
            let components = version.standardizedFileURL.pathComponents
            let isRunning = runningExecutables.contains { executable in
                let executableComponents = executable.standardizedFileURL.pathComponents
                return executableComponents.count > components.count
                    && Array(executableComponents.prefix(components.count)) == components
            }
            if isRunning { retained.insert(version.lastPathComponent) }
        }

        return retained
    }

    /// Follows an alias to the version it names.
    ///
    /// nvm aliases chain — `default` → `lts/*` → `lts/krypton` → `v22.22.2` —
    /// and an alias may also be a *partial* version (`22`), which selects the
    /// highest installed match. The seen-set is not defensive programming: an
    /// alias file the user has edited can point at itself, and without it this
    /// loops forever inside a scan.
    static func resolve(
        _ token: String, in names: [String], resolveAlias: (String) -> String?
    ) -> String? {
        var current = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []

        while seen.insert(current).inserted {
            // `node` and `*` are nvm's names for "the latest installed", not
            // aliases on disk.
            if current == "node" || current == "*" { return highest(of: names) }
            if let exact = names.first(where: { $0 == current || $0 == "v" + current }) {
                return exact
            }
            if let next = resolveAlias(current)?.trimmingCharacters(in: .whitespacesAndNewlines),
                next.isEmpty == false
            {
                current = next
                continue
            }
            // A partial version: `22` or `v22` selects the highest `v22.*`.
            let prefix = current.hasPrefix("v") ? current : "v" + current
            let matches = names.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
            return highest(of: matches)
        }
        return nil
    }

    /// The highest version name, compared numerically component by component.
    ///
    /// Lexicographic ordering is the bug this exists to avoid: it puts
    /// `v20.9.0` above `v20.13.1`, which would retain the wrong version and
    /// offer the one actually in use.
    static func highest(of names: [String]) -> String? {
        names.max { left, right in components(of: left).lexicographicallyPrecedes(
            components(of: right)) }
    }

    private static func components(of name: String) -> [Int] {
        name.drop(while: { $0 == "v" })
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
