import Foundation

/// What path-pattern discovery produced, and what it could not see.
///
/// A named struct rather than a tuple: this gained a field once and will gain
/// another, and a tuple makes every call site pay for that each time.
public struct DiscoveryReport: Sendable {
    public let candidates: [Candidate]
    /// Declared paths, and enumeration parents, that exist but could not be
    /// read, identified by path so the same physical directory refused again
    /// by `walk` can be recognised as one refusal rather than two. Never
    /// gains a path for one that is simply not present — most profile paths
    /// are absent on any given machine, and counting absence would drown the
    /// caveat that matters.
    public let refusals: RefusalSet

    public init(candidates: [Candidate], refusals: RefusalSet) {
        self.candidates = candidates
        self.refusals = refusals
    }
}

/// What the name-matching walk produced, and what it could not enter.
public struct WalkReport: Sendable {
    public let candidates: [Candidate]
    public let outcome: ScanOutcome
    /// Directories the enumerator was refused, plus one for a root it could
    /// not enumerate at all, identified by path. `FileFinder` has counted its
    /// equivalent for longer; this is the same fact from the
    /// other engine — and because it is a `RefusalSet` rather than a tally,
    /// a directory this walk and `discoverPathPatterns` both reach can be
    /// unioned down to one refusal instead of summed into two.
    public let refusals: RefusalSet

    public init(candidates: [Candidate], outcome: ScanOutcome, refusals: RefusalSet) {
        self.candidates = candidates
        self.outcome = outcome
        self.refusals = refusals
    }
}

public actor FileScanner {
    private var isCancelled = false

    public init() {}

    public func cancel() { isCancelled = true }

    public func resetCancellation() { isCancelled = false }

    /// True when either the actor flag or the surrounding task was cancelled.
    private var shouldStop: Bool { isCancelled || Task.isCancelled }

    // MARK: - Path-based discovery

    /// Handles `.absolutePath`, `.subdirectories`, and `.childSubpath`.
    /// `home` is injectable so tests can point it at a fixture tree.
    public func discoverPathPatterns(
        profiles: [ScanProfile],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runningExecutables: @Sendable () -> [URL]? = { RunningExecutables.current() }
    ) -> DiscoveryReport {
        var candidates: [Candidate] = []
        // Gathered raw and turned into a `RefusalSet` once at each return
        // point, as `Measurer.measure` does. Folding each refusal in with
        // `union` re-collapses the whole set every time, which is what makes
        // accumulating one path at a time quadratic.
        var refusedPaths: Set<String> = []

        func refuse(_ url: URL) {
            refusedPaths.insert(Candidate.normalizedPathKey(for: url))
        }

        func currentRefusals() -> RefusalSet {
            RefusalSet(paths: refusedPaths)
        }

        for profile in profiles {
            for pattern in profile.patterns {
                if shouldStop { return DiscoveryReport(
                    candidates: candidates, refusals: currentRefusals()) }

                switch pattern.kind {
                case .absolutePath(let raw):
                    let url = expand(raw, home: home)
                    switch probeDirectory(url) {
                    case .absent, .notADirectory:
                        continue
                    case .unreadable:
                        refuse(url)
                        continue
                    case .directory:
                        candidates.append(makeCandidate(
                            path: url, profile: profile, pattern: pattern,
                            specificity: .explicit, name: url.lastPathComponent
                        ))
                    }

                case .subdirectories(let parentRaw, _):
                    let parent = expand(parentRaw, home: home)
                    let listing = childDirectories(of: parent)
                    refusedPaths.formUnion(listing.refusals.paths)
                    for child in listing.children {
                        if shouldStop { return DiscoveryReport(
                            candidates: candidates, refusals: currentRefusals()) }
                        candidates.append(makeCandidate(
                            path: child, profile: profile, pattern: pattern,
                            specificity: .enumerated, name: child.lastPathComponent
                        ))
                    }

                case .engineVersions(let parentRaw, let engine, _):
                    let parent = expand(parentRaw, home: home)
                    let listing = childDirectories(of: parent)
                    refusedPaths.formUnion(listing.refusals.paths)

                    // Read once per pattern rather than per directory: the
                    // answer does not depend on which version is being judged,
                    // and for Godot it opens an Info.plist per app bundle.
                    let retained: Set<String>
                    switch engine {
                    case .unity:
                        // Unity's version directories ARE the installs, so
                        // "what is installed" would retain every one of them.
                        // Retention comes from what projects pin, plus the
                        // newest -- see `retainedEditorVersions`.
                        retained = engine.retainedEditorVersions(
                            among: listing.children.map(\.lastPathComponent))
                    case .godot, .unreal:
                        retained = engine.installedVersions()
                    }

                    for version in EngineVersions.stale(
                        among: listing.children, retaining: retained
                    ) {
                        if shouldStop { return DiscoveryReport(
                            candidates: candidates, refusals: currentRefusals()) }
                        candidates.append(makeCandidate(
                            path: version, profile: profile, pattern: pattern,
                            specificity: .enumerated, name: version.lastPathComponent
                        ))
                    }

                case .toolchainVersions(let parentRaw, let pointerRaw, let aliasRaw, _):
                    let parent = expand(parentRaw, home: home)
                    let listing = childDirectories(of: parent)
                    refusedPaths.formUnion(listing.refusals.paths)

                    // A retention rule that could not be evaluated is not a
                    // rule that found nothing. An alias file that will not
                    // open reads exactly like one that is not there, and the
                    // version it names is then offered while the manager
                    // points straight at it. Absent is fine and common —
                    // most managers declare a pointer they have not written
                    // yet — so only a read that *failed* counts here.
                    var evidenceUnreadable = false
                    func readRetentionFile(_ url: URL) -> String? {
                        do {
                            return try String(contentsOf: url, encoding: .utf8)
                        } catch {
                            if !PathAccess.isAbsent(error) { evidenceUnreadable = true }
                            return nil
                        }
                    }

                    let pointer = pointerRaw
                        .map { expand($0, home: home) }
                        .flatMap(readRetentionFile)
                    let aliasDirectory = aliasRaw.map { expand($0, home: home) }

                    let offered = ToolchainVersions.stale(
                        among: listing.children,
                        pointer: pointer,
                        resolveAlias: { name in
                            guard let aliasDirectory else { return nil }
                            // An alias name can carry a subdirectory
                            // (`lts/krypton`), so it is appended as a path
                            // rather than as one component.
                            return readRetentionFile(aliasDirectory.appending(path: name))
                        },
                        runningExecutables: runningExecutables()
                    )

                    // Refused rather than offered, and recorded as a refusal
                    // so the total reads as a floor instead of quietly
                    // dropping these versions from the sweep.
                    guard !evidenceUnreadable else {
                        refusedPaths.insert(Candidate.normalizedPathKey(for: parent))
                        continue
                    }

                    for version in offered {
                        if shouldStop { return DiscoveryReport(
                            candidates: candidates, refusals: currentRefusals()) }
                        candidates.append(makeCandidate(
                            path: version, profile: profile, pattern: pattern,
                            specificity: .enumerated, name: version.lastPathComponent
                        ))
                    }

                case .childSubpath(let parentRaw, let subpath, _):
                    let parent = expand(parentRaw, home: home)
                    let listing = childDirectories(of: parent)
                    refusedPaths.formUnion(listing.refusals.paths)
                    for child in listing.children {
                        if shouldStop { return DiscoveryReport(
                            candidates: candidates, refusals: currentRefusals()) }
                        let target = child.appending(path: subpath, directoryHint: .isDirectory)
                        switch probeDirectory(target) {
                        case .absent, .notADirectory:
                            continue
                        case .unreadable:
                            refuse(target)
                            continue
                        case .directory:
                            candidates.append(makeCandidate(
                                path: target, profile: profile, pattern: pattern,
                                specificity: .enumerated, name: child.lastPathComponent
                            ))
                        }
                    }

                case .directoryName:
                    continue   // handled by walk(), not path-based discovery
                }
            }
        }

        return DiscoveryReport(candidates: candidates, refusals: currentRefusals())
    }

    // MARK: - Filesystem walk

    /// Directory names never descended into.
    ///
    /// `Library` appears here because the walk normally starts at the user's
    /// home directory and everything under `~/Library` is covered by explicit
    /// absolute-path patterns instead, which is both faster and more precise.
    ///
    /// Not private: `FinderSkipList` unions this with the profile-derived
    /// names so the Files view inherits the same exclusions rather than
    /// keeping a second copy that has to be remembered.
    static let skipDirectories: Set<String> = [
        ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        "Applications", "System", "Library",
        ".git", ".svn", ".hg",
    ]

    private struct WalkPattern {
        let marker: ScanProfile.Pattern.Marker?
        let tier: RemovalTier
        let removability: Removability
        let category: CleanCategory
    }

    /// Handles `.directoryName`. Reports one coalesced progress path per
    /// directory *matched*, not per directory visited, to avoid a
    /// MainActor hop per directory in the home tree.
    public func walk(
        root: URL,
        profiles: [ScanProfile],
        onProgress: @Sendable (String) -> Void
    ) -> WalkReport {
        var lookup: [String: [WalkPattern]] = [:]
        for profile in profiles {
            for pattern in profile.patterns {
                guard case .directoryName(let name, let marker) = pattern.kind else { continue }
                lookup[name, default: []].append(WalkPattern(
                    marker: marker,
                    tier: pattern.tier,
                    removability: pattern.removability,
                    category: profile.category
                ))
            }
        }
        guard lookup.isEmpty == false else {
            return WalkReport(candidates: [], outcome: .finished, refusals: .none)
        }

        // A class so the errorHandler closure and this scope share one set.
        // Paths are gathered raw and turned into a `RefusalSet` only when a
        // `WalkReport` is actually returned below, rather than through
        // `union` on every refusal: `RefusalSet.init` collapses descendant
        // paths, so folding one path in at a time re-collapsed the whole
        // set on every refusal, which is quadratic in a heavily refused
        // tree.
        final class Failures {
            var paths: Set<String> = []
            var refusals: RefusalSet { RefusalSet(paths: paths) }
        }
        let failures = Failures()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { url, error in
                // Absence is not denial here either: a path that disappeared
                // between listing and visiting is not a refusal.
                if !PathAccess.isAbsent(error) {
                    failures.paths.insert(Candidate.normalizedPathKey(for: url))
                }
                // Keep walking. Refusals are gathered raw here and collapsed
                // into a `RefusalSet` once, when the walk actually returns one.
                return true
            }
        ) else {
            // The root itself could not be enumerated. Returning `.finished`
            // with an empty list was a clean, complete, confident answer for a
            // tree that was never seen.
            return WalkReport(
                candidates: [], outcome: .finished,
                refusals: RefusalSet(paths: [Candidate.normalizedPathKey(for: root)]))
        }

        var candidates: [Candidate] = []

        for case let fileURL as URL in enumerator {
            if shouldStop {
                return WalkReport(
                    candidates: candidates, outcome: .cancelled,
                    refusals: failures.refusals)
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { continue }

            let name = fileURL.lastPathComponent

            // Descent is refused for a skipped name no matter what follows.
            // The interior of ~/Library belongs to the Caches view, and
            // walking it here would report the same bytes a second time
            // without a tier to explain them. What changes below is only
            // whether the skipped directory ITSELF can be claimed.
            let isSkipped = Self.skipDirectories.contains(name)
            if isSkipped {
                enumerator.skipDescendants()
            }

            guard let walkPatterns = lookup[name] else { continue }

            let directory = fileURL.standardizedFileURL
            for walkPattern in walkPatterns {
                // A skipped name may only be claimed by a pattern that proves
                // what it found. `Library` is both a Unity project's import
                // cache and the name of ~/Library; an unmarked pattern cannot
                // tell the two apart, and the mistake would offer the user
                // their entire Library folder. Requiring a marker makes the
                // claim conditional on evidence rather than on the name.
                if isSkipped && walkPattern.marker == nil { continue }
                if let marker = walkPattern.marker,
                   marker.matches(directory: directory) == false {
                    continue
                }

                candidates.append(Candidate(
                    path: directory,
                    category: walkPattern.category,
                    tier: walkPattern.tier,
                    removability: walkPattern.removability,
                    specificity: .explicit,
                    displayName: "\(walkPattern.category.rawValue): \(name)"
                ))
                onProgress(directory.path(percentEncoded: false))
                // A matched artifact's interior is never itself interesting.
                enumerator.skipDescendants()
                break
            }
        }

        return WalkReport(
            candidates: candidates, outcome: shouldStop ? .cancelled : .finished,
            refusals: failures.refusals)
    }

    // MARK: - Helpers

    private func makeCandidate(
        path: URL,
        profile: ScanProfile,
        pattern: ScanProfile.Pattern,
        specificity: Specificity,
        name: String
    ) -> Candidate {
        Candidate(
            path: path,
            category: profile.category,
            tier: pattern.tier,
            removability: pattern.removability,
            specificity: specificity,
            displayName: "\(profile.category.rawValue): \(name)"
        )
    }

    private func expand(_ rawPath: String, home: URL) -> URL {
        guard rawPath.hasPrefix("~") else {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }
        let relative = String(rawPath.dropFirst(2))   // drop "~/"
        return home.appending(path: relative, directoryHint: .isDirectory).standardizedFileURL
    }

    /// The three answers a path can give, kept apart.
    ///
    /// Collapsing them into `Bool` via `try?` makes "I was refused"
    /// indistinguishable from "there is nothing here" — and the second is the
    /// common case, so the first inherits its silence.
    private enum DirectoryProbe {
        case directory
        /// Present, but not a directory. Not an error and not counted.
        case notADirectory
        /// Not there. Not counted: absence is not denial.
        case absent
        /// Present and refused. Counted.
        case unreadable
    }

    private func probeDirectory(_ url: URL) -> DirectoryProbe {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true ? .directory : .notADirectory
        } catch {
            return PathAccess.isAbsent(error) ? .absent : .unreadable
        }
    }

    /// Immediate subdirectories of `parent`, hidden ones included. Hidden
    /// directories are kept because bundle-identifier and dot-prefixed cache
    /// directories are exactly what the profiles target.
    ///
    /// Returns the refusal alongside the children rather than swallowing it:
    /// an unreadable enumeration parent otherwise yields an empty list,
    /// silently removing every candidate underneath it. `~/Library/Application Support`
    /// is such a parent, and it holds whole categories. The refusal is
    /// identified by path — the parent's own, when the listing itself fails;
    /// each child's, when the listing succeeds but probing one child does not
    /// — so the same directory refused again by `walk` can be recognised as
    /// one refusal rather than two.
    private func childDirectories(of parent: URL) -> (children: [URL], refusals: RefusalSet) {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            if PathAccess.isAbsent(error) { return ([], .none) }
            return ([], RefusalSet(paths: [Candidate.normalizedPathKey(for: parent)]))
        }

        var children: [URL] = []
        // Gathered raw and turned into a `RefusalSet` once at the end,
        // rather than through `union` on every refused child, which
        // re-collapsed the whole set each time.
        var refusedPaths: Set<String> = []
        for url in contents {
            switch probeDirectory(url) {
            case .directory: children.append(url)
            case .notADirectory, .absent: continue
            case .unreadable:
                refusedPaths.insert(Candidate.normalizedPathKey(for: url))
            }
        }
        return (children, RefusalSet(paths: refusedPaths))
    }
}
