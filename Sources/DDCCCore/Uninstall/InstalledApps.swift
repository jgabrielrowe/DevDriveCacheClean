// Sources/DDCCCore/Uninstall/InstalledApps.swift
import Foundation
import AppKit
import os

/// One application bundle found on disk, identified by the bundle
/// identifier its own `Info.plist` declares.
public struct InstalledApp: Sendable, Equatable {
    public let bundleID: String
    public let bundleURL: URL
    public let displayName: String
}

extension InstalledApps {

    /// Whether `bundleURL` sits inside another `.app`.
    ///
    /// `scan` walks four levels deep to find editors nested under a hub
    /// directory, and that depth also carries it *into* bundles: on one machine
    /// 161 of 425 discovered apps were nested helpers.
    ///
    /// They are not separate installs. A nested helper's bytes are already
    /// inside its parent's bundle, so offering both double-counts, and no
    /// path-based dedup catches it because a helper's path is a descendant
    /// rather than a duplicate.
    ///
    /// Lexical by design: it asks whether any ancestor component ends in
    /// `.app`, without touching the filesystem, so a directory merely named
    /// `Archive.app` reads as nested. That error hides a row, where the
    /// opposite error double-counts.
    public static func isNestedInsideAnotherBundle(_ bundleURL: URL) -> Bool {
        // `dropLast()` removes the bundle's own component, so an app whose
        // own name ends in `.app` is not nested by virtue of itself.
        bundleURL.standardizedFileURL.pathComponents
            .dropLast()
            .contains { $0.lowercased().hasSuffix(".app") }
    }
}

/// What one directory listing found, keeping "could not look" apart from
/// "looked and found nothing".
///
/// Three cases rather than an array that may be empty, because those two
/// facts are opposites everywhere this uninstaller uses a listing: a name
/// that is missing from what a directory holds is what proves an application
/// gone and releases the data it left behind, and a directory that could not
/// be read supplies no names at all. See `InstalledApps.listing(of:before:reading:)`.
enum DirectoryListing: Equatable, Sendable {
    /// Read. `entries` is everything directly inside, and no entries is a
    /// genuine finding: this directory holds nothing.
    case listed(entries: [URL])

    /// No such directory. Not a failure to read one — a directory that is not
    /// there holds nothing, which is a reading, and callers may treat it
    /// exactly as they treat `.listed(entries: [])`. The common case for the
    /// fixed roots swept here.
    case absent

    /// It exists and this could not read it: permissions, an I/O error, a
    /// deadline that expired on a stalled mount, or a path that is not a
    /// directory. An absence of information, never an empty finding.
    case unreadable
}

/// The ground-truth index of every application installed on this machine.
///
/// Almost every safety rule downstream is phrased against this: "is this
/// directory's owner still installed?", "does another app still claim this
/// shared container?", "is this app absent, making its leftovers
/// removable?". Under-reporting here does not produce an empty list — it
/// produces a *wrong* one, and a wrong one gets read as "safe to delete."
/// That is the failure mode this type exists to prevent, so both of its
/// sources are treated as necessary and neither is trusted alone:
///
/// - **The disk scan**, because a bundle can be installed without ever being
///   registered with Launch Services — a fresh unzip, or an app dragged in and
///   never opened. It walks deep because real installs nest: a depth-2 scan
///   missed Unity's editors and reported a live install as a leftover, the
///   exact false "this app is gone" verdict that made orphan detection
///   unshippable here. See `maxScanDepth`.
/// - **Launch Services**, because it knows about apps outside the scan's
///   roots. On one machine it alone resolved 68 of 733 container entries;
///   unioned with the disk scan that rose to 308. Neither source alone is
///   adequate.
public struct InstalledApps: Sendable {

    /// Every bundle the disk scan actually found, keyed by bundle
    /// identifier. Each entry has a real, scanned `bundleURL` — this is the
    /// set a caller can act on (read a footprint, check an entitlement,
    /// compute a size). An id known only to Launch Services deliberately
    /// does **not** appear here, because this type has no real path for it;
    /// see `isInstalled(_:)` for how that id is still recognized as
    /// installed.
    public let byID: [String: InstalledApp]

    /// Every `.app` filename the disk walk found, before any `Info.plist`
    /// was opened.
    ///
    /// Deliberately not derived from `byID`. The scan is partial-tolerant: a
    /// bundle whose `Info.plist` cannot be read, or that declares no
    /// `CFBundleIdentifier`, is skipped when `byID` is built, so `byID` comes
    /// back short of a bundle that is unambiguously sitting on disk. A caller
    /// asking "is anything by this name installed?" and reading that absence
    /// as absence would be reading a parse failure as an uninstall — and
    /// downstream that means offering a live product's directory for
    /// deletion. A filename is all such a question needs, and the walk knows
    /// every filename it found whatever the plist said.
    ///
    /// Filenames as they appear on disk, `.app` extension included, and not
    /// case-folded: a caller compares through its own key derivation.
    /// Includes helper bundles nested inside other bundles, and includes a
    /// `.app` the walk could not confirm is a directory at all, on the same
    /// reasoning — a name that is present must not read as missing. Both
    /// choices can only add a name, and a name can only add a refusal.
    ///
    /// Bounded by the scan roots, so a bundle installed outside them is in
    /// neither this nor `byID`. `isInstalled(_:)`'s Launch Services union
    /// cannot close that gap here, because it answers for a bundle
    /// identifier and this question is asked by filename. A caller asking
    /// the presence question unions this with
    /// `bundleFilenames(directlyUnder:within:)` over `presenceOnlyRoots()`, which
    /// covers the locations outside the roots without widening what counts
    /// as an installed application.
    public let discoveredBundleFilenames: Set<String>

    /// False when the walk could not read some directory under the scan
    /// roots, so `discoveredBundleFilenames` is short by every bundle that
    /// lived under it.
    ///
    /// The walk drops a subtree it cannot list rather than abandoning the
    /// scan, which is right — one unreadable directory must not cost the
    /// other 52,000 — but it leaves the set short with nothing saying so, and
    /// short is the dangerous direction: a name missing from this set is half
    /// of what proves a cask absent and releases the paths it was refusing. A
    /// caller proving an absence has to require this, exactly as it requires
    /// the presence sweep's own `fullyRead`.
    ///
    /// Records only what could not be *read*. A root that does not exist is
    /// not a gap — `~/Applications` is missing on most machines — and neither
    /// is the depth bound: `maxScanDepth` is a deliberate limit on how far the
    /// walk goes, not a directory it failed to open, and treating it as one
    /// would report almost every machine short and withhold the app signal
    /// entirely.
    public let discoveredBundleFilenamesFullyRead: Bool

    /// Injected Launch Services probe, consulted live rather than folded
    /// into `byID` at scan time — it can answer for any identifier, not
    /// just ones the scan happened to enumerate, so there is nothing to
    /// pre-compute. Memoized per id; see `LaunchServicesMemo`.
    private let launchServices: LaunchServicesMemo

    fileprivate init(
        byID: [String: InstalledApp],
        discoveredBundleFilenames: Set<String>,
        discoveredBundleFilenamesFullyRead: Bool,
        launchServices: LaunchServicesMemo
    ) {
        self.byID = byID
        self.discoveredBundleFilenames = discoveredBundleFilenames
        self.discoveredBundleFilenamesFullyRead = discoveredBundleFilenamesFullyRead
        self.launchServices = launchServices
    }

    /// True if `id` is installed by either source. This *is* the union the
    /// type exists to provide: a bundle the disk scan found, OR an
    /// identifier Launch Services vouches for. See the type's doc comment
    /// for the measurement that makes checking only one of them wrong.
    ///
    /// `byID` is a frozen snapshot, but an id outside it is answered live by
    /// Launch Services, so two calls could in principle straddle a real
    /// registration change. The probe is memoized per id, so within one
    /// instance the answer is fixed from its first query onward. Concurrent
    /// first-calls for the same id can both miss the cache and both probe — see
    /// `LaunchServicesMemo.isInstalled`.
    public func isInstalled(_ id: String) -> Bool {
        byID[id] != nil || launchServices.isInstalled(id)
    }
}

/// Caches the injected Launch Services probe's answer per bundle identifier.
///
/// Without this, every id outside `byID` — most of them; on one machine 666 of
/// 735 container-derived ids matched neither source — costs a synchronous
/// Launch Services round trip on every check, and `isInstalled` is called for
/// the same id from several stages, so the cost multiplies by call sites rather
/// than by ids. A `final class` wrapping a lock rather than a struct, because
/// the memo must be one shared table reachable from every copy of the
/// `Sendable` value holding it.
private final class LaunchServicesMemo: Sendable {
    private let state: OSAllocatedUnfairLock<[String: Bool]>
    private let probe: @Sendable (String) -> Bool

    init(probe: @escaping @Sendable (String) -> Bool) {
        self.state = OSAllocatedUnfairLock(initialState: [:])
        self.probe = probe
    }

    /// Two short critical sections, never one spanning the probe call. `probe`
    /// is a synchronous out-of-process Launch Services query, and
    /// `os_unfair_lock` is for very short sections only: holding it across that
    /// call would serialize every concurrent `isInstalled` for any id behind
    /// whichever call is blocked, risking priority inversion.
    ///
    /// The accepted trade is that two concurrent first-calls for the same id
    /// can both probe. `probe` is idempotent and a duplicate is cheap, and
    /// coalescing would need per-id machinery. Do not move the probe call back
    /// inside `withLock`.
    func isInstalled(_ id: String) -> Bool {
        if let cached = state.withLock({ $0[id] }) {
            return cached
        }
        let result = probe(id)
        state.withLock { $0[id] = result }
        return result
    }
}

extension InstalledApps {

    /// How many directory levels the scan descends looking for a top-level
    /// `.app`. Measured: Unity's editors sit four levels below
    /// `/Applications`
    /// (`/Applications/Unity/Hub/Editor/6000.5.6f1/Unity.app`); a depth-2
    /// scan missed them entirely. Six leaves headroom above the worst case
    /// measured on this machine — do not lower this without re-measuring,
    /// and see `InstalledAppsTests.anAppNestedFourLevelsDeepIsStillFound`,
    /// which mutation-tests this exact constant.
    public static let maxScanDepth = 6

    /// Where macOS actually keeps application bundles. `~/Applications` is
    /// included even though it is rare, because a per-user install is
    /// exactly the kind of thing a Launch Services–only view would miss if
    /// the scan skipped it, and a directory that does not exist is simply
    /// skipped rather than treated as an error.
    public static var defaultRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Where an application bundle can sit without `defaultRoots` ever
    /// seeing it, swept for **presence only**.
    ///
    /// A cask is proved absent by its `app` artifact naming no filename the
    /// machine has, so a bundle outside the scan roots — dragged to
    /// `/Users/Shared`, installed under `/opt`, living on an external volume
    /// — makes its own product look uninstalled and lets a shared directory
    /// it still uses be released. Widening what the *presence* question sees
    /// can only add filenames, so it can only ever add refusals; it never
    /// releases anything the narrower sweep would have kept.
    ///
    /// Deliberately not the roots that mint uninstall rows. What counts as an
    /// installed application, and whether a bundle on an external volume is
    /// one, is a product question this does not answer — it only refuses to
    /// call such a bundle absent.
    ///
    /// Lists `/Volumes` to find the mounted volumes, bounded by
    /// `listingBudget`, because `/Volumes` is where a stale network mount
    /// shows up and a listing of it is not guaranteed to answer. A listing
    /// that does not answer contributes no volume roots — and `/Volumes` is
    /// itself returned as a root, so that gap is not silent: `bundleFilenames`
    /// reads it again and marks the sweep short when it cannot.
    public static func presenceOnlyRoots() -> [URL] {
        var roots = [
            URL(fileURLWithPath: "/opt", isDirectory: true),
            URL(fileURLWithPath: "/opt/Applications", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
        ]
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        // Returned as a root of the sweep in its own right, not only read for
        // the volumes below it. Losing this listing loses every volume root it
        // would have produced, so it is exactly the kind of short read the
        // sweep must report — and it reports one by failing to read a root it
        // was handed. This returns roots, not a completeness flag, so handing
        // the same directory back is what says so.
        roots.append(volumes)
        // Absent or unreadable, this contributes no volume roots either way.
        if case .listed(let mounted) = listing(of: volumes, before: .now() + listingBudget) {
            for volume in mounted {
                roots.append(volume)
                roots.append(volume.appending(path: "Applications", directoryHint: .isDirectory))
            }
        }
        return roots
    }

    /// How long one directory listing in the presence sweep gets before it is
    /// abandoned. Per listing, not per sweep: a stalled mount must not spend
    /// the time the readable roots needed, since a root that contributes
    /// nothing is the direction that permits a release. The whole sweep is
    /// therefore bounded by this times the number of roots — a handful of
    /// seconds even on a machine with several dead mounts, against a
    /// `contentsOfDirectory` on a stale mount that has no bound at all.
    ///
    /// Generous by design. A working filesystem answers a shallow listing in
    /// microseconds, so this is only ever reached by one that is not working.
    public static let listingBudget: TimeInterval = 2

    /// Every `.app` filename directly inside `roots` — one listing per root, no
    /// recursion.
    ///
    /// Shallow on purpose: this answers "is anything by this name here?", and a
    /// name only ever widens a refusal. It supplements `scan` and never
    /// substitutes for it, because contributing nothing is the direction that
    /// permits a release. Filenames as they appear on disk, extension included
    /// and not case-folded, so they union directly with
    /// `discoveredBundleFilenames`.
    ///
    /// Each root gets `within` seconds and is abandoned if it does not answer:
    /// `/Volumes` puts stale network mounts on this list.
    ///
    /// `fullyRead` is false when a root exists and would not answer —
    /// permissions, an I/O error, or a spent deadline. A root that is simply
    /// absent does not clear it: three of the four fixed roots are missing on a
    /// typical machine, and a directory that does not exist holds nothing.
    /// `DirectoryListing` keeps the two apart.
    ///
    /// The flag travels beside the filenames because neither substitutes for
    /// it. A short set reads as the machine's apps, so a name missing from it
    /// proves a cask absent and releases the paths it was refusing; and the
    /// caller unions this with the scan's own names, so a short sweep beside a
    /// full scan is non-empty and looks complete.
    public static func bundleFilenames(
        directlyUnder roots: [URL], within budget: TimeInterval = listingBudget
    ) -> (filenames: Set<String>, fullyRead: Bool) {
        bundleFilenames(
            directlyUnder: roots, within: budget, reading: InstalledApps.contentsOfDirectory)
    }

    /// `bundleFilenames(directlyUnder:within:)` with the directory read
    /// supplied, which is the only way to reach the deadline on purpose.
    ///
    /// The behaviour worth pinning is a listing that does not come back, and
    /// no real directory on a test machine can be made to do that — the
    /// alternative is a zero budget, which reaches the abandoned path only
    /// because a semaphore has not been signalled yet, and that is a race, not
    /// a test. Injecting the read makes the stall the fixture rather than the
    /// timing.
    static func bundleFilenames(
        directlyUnder roots: [URL], within budget: TimeInterval,
        reading: @escaping @Sendable (URL) throws -> [URL]
    ) -> (filenames: Set<String>, fullyRead: Bool) {
        var filenames: Set<String> = []
        var fullyRead = true
        // Resolved, and deduplicated by where they resolve to.
        //
        // `/Volumes/Macintosh HD` is a symlink to `/` on essentially every
        // modern Mac, and asking for its contents fails with the same error an
        // unreadable directory gives, while `/` lists perfectly well. Handed
        // over unresolved it made every sweep read short, which withheld the
        // app signal from every absence proof — the whole point of the sweep,
        // inverted by one firmlink. Same shape as a bundle whose type will not
        // confirm: a symlink to something readable is not unreadable.
        //
        // Deduplicating on the resolved path is not just thrift. That firmlink
        // also yields `/Volumes/Macintosh HD/Applications`, which is
        // `/Applications` again, so the boot volume's bundles were enumerated
        // twice and a stalled second reading of them could report short over
        // names already in hand.
        var visited: Set<String> = []
        for root in roots.map({ $0.resolvingSymlinksInPath() })
        where visited.insert(root.standardizedFileURL.path).inserted {
            switch listing(of: root, before: .now() + budget, reading: reading) {
            case .listed(let entries):
                for entry in entries where entry.pathExtension == "app" {
                    filenames.insert(entry.lastPathComponent)
                }
            // A root that is not there holds no bundles, and that is a
            // reading, not a gap: three of the four fixed roots are missing on
            // a typical machine, so marking these short would withhold the app
            // signal everywhere.
            case .absent:
                continue
            // Whereas a root that exists and would not answer — no permission,
            // an I/O error, a deadline spent on a stalled mount — leaves this
            // set short by exactly the bundles it holds, and a missing name is
            // what proves a cask absent.
            case .unreadable:
                fullyRead = false
            }
        }
        return (filenames, fullyRead)
    }

    /// The default directory read: everything directly inside `directory`,
    /// with no resource values prefetched.
    static let contentsOfDirectory: @Sendable (URL) throws -> [URL] = { directory in
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [])
    }

    /// One directory listing, answering in the three states a listing really
    /// has rather than the two an array can carry.
    ///
    /// Every absence rule in this uninstaller is phrased against a name that
    /// is *not* there — a cask is proved absent by no installed bundle
    /// matching its `app` artifact — so a directory this could not read hands
    /// the caller the same empty array as a directory that genuinely holds no
    /// applications, and the caller reads "could not look" as "there is
    /// nothing there" and releases a live product's data. Returning
    /// `DirectoryListing` makes that a decision each caller has to make in the
    /// open instead of a distinction it never receives.
    ///
    /// `.absent` is separated from `.unreadable` because they are separated in
    /// the safety argument, not for tidiness: a directory that does not exist
    /// is the common case here — three of the four fixed presence roots are
    /// missing on a typical machine — and it holds nothing, which is a
    /// reading. Only `ENOENT` is `.absent`; every other failure, including a
    /// path that turns out not to be a directory, is `.unreadable`, so an
    /// error this does not recognize refuses rather than releases.
    ///
    /// `deadline` bounds how long the read is waited for. `nil` waits as long
    /// as it takes, which is what a local walk wants; a real deadline is for
    /// roots that may not answer at all, and a read that misses it is
    /// `.unreadable` — nothing was learned, exactly as with a permission
    /// error. A bounded read runs on a global-queue thread and is not
    /// cancelled, because nothing can cancel a blocked `getdirentries`:
    /// abandoning it frees this caller, and the thread's result is dropped
    /// whenever the filesystem finally answers.
    static func listing(
        of directory: URL,
        before deadline: DispatchTime?,
        reading: @escaping @Sendable (URL) throws -> [URL] = InstalledApps.contentsOfDirectory
    ) -> DirectoryListing {
        let read: @Sendable () -> DirectoryListing = {
            do {
                return .listed(entries: try reading(directory))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return .absent
            } catch {
                return .unreadable
            }
        }
        guard let deadline else { return read() }

        let answer = OSAllocatedUnfairLock<DirectoryListing?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = read()
            answer.withLock { $0 = outcome }
            finished.signal()
        }
        guard finished.wait(timeout: deadline) == .success else { return .unreadable }
        // The lock is only ever written before `signal()`, so a successful
        // wait has the answer; the fallback exists to avoid forcing it.
        return answer.withLock { $0 } ?? .unreadable
    }

    /// A nested `.app`'s own search depth inside another bundle's
    /// `Contents`, independent of `maxDepth`. Helper bundles are not deeply
    /// nested in practice — `com.microsoft.VSCode.ShipIt` sits directly
    /// under `Contents/Frameworks/Squirrel.framework/Resources` — but the
    /// bound exists so a pathological bundle cannot make this walk
    /// unbounded the way an unrelated top-level `maxDepth` argument would
    /// not protect against.
    private static let helperSearchDepth = 8

    /// Scans `roots` for installed application bundles and unions the
    /// result with `launchServices`. See the type's doc comment for why
    /// both are necessary.
    ///
    /// A helper `.app` bundle nested inside another bundle's `Contents` is
    /// enumerated as its own, separately installed identity —
    /// `com.microsoft.VSCode.ShipIt` is a real example on this machine and
    /// owns a 1.46 GB cache directory under its own bundle id. The walk
    /// does **not** descend into a `.app` looking for further *top-level*
    /// apps; it only looks inside `Contents` for helpers.
    ///
    /// Every subtree is scanned independently: a permission error or a
    /// broken symlink drops only the directory it occurred in, never the
    /// whole scan, and a `.app` with no readable `Info.plist` or no
    /// `CFBundleIdentifier` is skipped rather than crashing or aborting.
    public static func scan(
        roots: [URL] = InstalledApps.defaultRoots,
        maxDepth: Int = InstalledApps.maxScanDepth,
        launchServices: @escaping @Sendable (String) -> Bool = { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    ) -> InstalledApps {
        var bundleURLs: [URL] = []
        var visited: Set<String> = []
        var fullyRead = true
        for root in roots {
            collectApps(
                from: root, depth: 0, maxDepth: maxDepth, visited: &visited, into: &bundleURLs,
                fullyRead: &fullyRead)
        }

        // Taken from the walk's own output, before the parse loop below can
        // drop anything — see `discoveredBundleFilenames`.
        let discoveredBundleFilenames = Set(bundleURLs.map(\.lastPathComponent))

        var byID: [String: InstalledApp] = [:]
        for bundleURL in bundleURLs {
            guard let info = readBundleInfo(at: bundleURL) else { continue }
            // First one found wins on a duplicate id; which physical copy
            // is "the" install is not this type's call to make.
            if byID[info.bundleID] == nil {
                byID[info.bundleID] = InstalledApp(
                    bundleID: info.bundleID, bundleURL: bundleURL, displayName: info.displayName)
            }
        }
        return InstalledApps(
            byID: byID, discoveredBundleFilenames: discoveredBundleFilenames,
            discoveredBundleFilenamesFullyRead: fullyRead,
            launchServices: LaunchServicesMemo(probe: launchServices))
    }

    /// Recursively collects `.app` bundle URLs under `directory`.
    ///
    /// `visited` is a set of canonicalized (symlink-resolved) paths shared
    /// across the whole scan, not just this call. Without it, a symlinked
    /// entry that points back at an ancestor — a legitimate possibility
    /// under `/Applications`, and trivially producible inside a bundle's own
    /// `Contents` — would recurse forever regardless of any depth counter,
    /// because entering a `.app` resets the depth counter used for its
    /// helper search back to zero.
    ///
    /// `fullyRead` is cleared, never set, and shared across the whole scan, so
    /// one unreadable directory anywhere marks the whole walk short and no
    /// later subtree can clear the mark. A directory that will not list still
    /// drops only itself — that is the right call, and it is why the fact has
    /// to travel out separately: the walk goes on and returns a set that is
    /// short by everything under it, and a name missing from that set is what
    /// proves a cask absent.
    private static func collectApps(
        from directory: URL,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<String>,
        into apps: inout [URL],
        fullyRead: inout Bool
    ) {
        // Neither of these two is a failure to read anything. The depth bound
        // is a deliberate limit on how far the walk goes — see `maxScanDepth`
        // — and an already-visited directory has been counted once already, so
        // marking either short would report almost every machine short and
        // withhold the app signal entirely.
        guard depth <= maxDepth else { return }

        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard visited.insert(canonical).inserted else { return }

        let entries: [URL]
        switch listing(
            of: directory, before: nil,
            reading: { try FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.isDirectoryKey], options: []) }
        ) {
        case .listed(let listed):
            entries = listed
        // Gone between discovery and read, or a bundle with no `Contents` —
        // 17 of them under this machine's scan roots. Nothing is there to
        // miss, so nothing is recorded.
        case .absent:
            return
        // Permissions, an I/O error, or a path that turned out not to be a
        // directory: this subtree is dropped and the scan is short by whatever
        // it held.
        case .unreadable:
            fullyRead = false
            return
        }

        // No deadline above, unlike the presence sweep: this walk covers
        // roughly 52,000 directories on a real machine, and bounding each one
        // would cost a thread hop apiece to guard against a stall the fixed
        // local scan roots do not have.

        for entry in entries {
            let type = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDirectory = type?.isDirectory

            guard entry.pathExtension == "app" else {
                // Not a bundle, so it carries no name this scan wants; it is
                // worth walking only for what may be under it. Unlike the
                // bundle arm below, a failed type read is not given the
                // benefit of the doubt here, and the reason is scope rather
                // than caution: a `.app`'s `Contents` is bounded to that
                // bundle, while descending anything else widens where
                // top-level apps may be found — a symlink out of a scan root
                // would pull an arbitrary tree into it.
                //
                // So this refuses a symlink and a regular file alike, both of
                // which the type read reports as `false`. It also refuses the
                // `nil` a type read that would not resolve returns, which is
                // the one conflation left in this walk. It costs nothing
                // measurable: zero non-`.app` entries are in that state under
                // this machine's four scan roots, and the only cause observed
                // for it is an entry that vanished between the listing and the
                // stat — which a descent would find absent anyway, silently,
                // for the same result. Stated rather than fixed, because a
                // guard no test can make fail is worth less than an accurate
                // note about why it is not there.
                guard isDirectory == true else { continue }
                collectApps(
                    from: entry, depth: depth + 1, maxDepth: maxDepth, visited: &visited,
                    into: &apps, fullyRead: &fullyRead)
                continue
            }

            // Kept whatever the type read said. A `.app` whose URL will not
            // confirm it is a directory is not thereby absent: the type read
            // resolves the path, so a symlink into a volume or a directory
            // this cannot traverse answers "not a directory" for a bundle that
            // is unambiguously installed. `discoveredBundleFilenames` needs
            // only the name, which the walk has either way, and that set is
            // what a cask's `app` artifact is matched against — a name missing
            // from it proves the cask absent and releases the paths it was
            // refusing. Keeping the name can only add a refusal; dropping it
            // can release a live product's data.
            //
            // Nothing downstream mistakes it for a readable bundle: `byID` is
            // built by parsing each one's `Info.plist`, and one that cannot be
            // read is skipped there exactly as any unparseable bundle is.
            apps.append(entry)

            // The listing decides whether this bundle can be descended, not
            // the type read. `/Applications/Safari.app` is a symlink into the
            // cryptex volume whose URL answers "not a directory" while its
            // `Contents` lists nine entries; all six bundles in that state on
            // a measured machine are listable. Refusing on the type read threw
            // away every helper inside them, and a helper missing from
            // `discoveredBundleFilenames` is a name a cask can be proved
            // absent by. The listing already separates "nothing there" from
            // "could not read", which is the distinction that was wanted.
            //
            // The type read is kept for the opposite finding, which it does
            // answer reliably. A confirmed regular file wearing the extension
            // has no `Contents` to ask for, and asking throws ENOTDIR —
            // unreadable, which would declare the whole scan short over one
            // stray file. So this refuses only what the filesystem confirmed
            // is a file, and lets a directory, a symlink, or a type that would
            // not resolve be settled by the listing.
            //
            // A symlink to a regular file would still read short. That is the
            // over-refusing direction, and no such entry exists under a
            // measured machine's scan roots, so it does not earn a second stat
            // to separate.
            guard type?.isRegularFile != true else { continue }

            // Helper bundles, not further top-level apps: search only
            // inside this bundle's own Contents, with its own depth
            // budget independent of the top-level walk's remaining
            // depth. Mutation-tested: making this branch also take the
            // top-level recursion (so a `.app` dropped anywhere inside
            // a bundle, e.g. `SharedSupport/Decoy.app`, becomes
            // reachable as a top-level identity) makes
            // aDecoyAppOutsideContentsOfAHostIsNotFoundAsATopLevelApp
            // fail.
            let contents = entry.appending(path: "Contents", directoryHint: .isDirectory)
            collectApps(
                from: contents, depth: 0, maxDepth: helperSearchDepth, visited: &visited,
                into: &apps, fullyRead: &fullyRead)
        }
    }

    /// Reads the identity out of a bundle's `Info.plist`, or `nil` if the
    /// bundle cannot supply one — no file, unreadable, malformed, or
    /// missing `CFBundleIdentifier`. `nil` here means "not counted," never
    /// a crash: a `.app` directory with a broken or absent `Info.plist` is
    /// not something this scan can identify, and guessing an identity for
    /// it would be worse than omitting it.
    private static func readBundleInfo(at bundleURL: URL) -> (bundleID: String, displayName: String)? {
        let infoPlistURL = bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty
        else { return nil }
        let displayName = (plist["CFBundleName"] as? String)
            ?? (plist["CFBundleDisplayName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return (bundleID, displayName)
    }
}
