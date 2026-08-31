// Sources/DDCCCore/Uninstall/UninstallCoordinator.swift
import Foundation
import AppKit
import os

/// One row in the sweep's output: either one app identity's whole assembled
/// footprint, or one artifact this engine can prove is dead independent of
/// any identity.
///
/// Two cases rather than one list with a discriminator: they answer different
/// questions and are sized on different scales — a footprint can be gigabytes,
/// a dead artifact is one manifest. The enum makes unpacking exhaustive.
public enum UninstallRow: Sendable {
    case app(AppFootprint)
    case deadArtifact(FootprintItem)
}

/// What the sweep produced, plus how honestly it knows that.
///
/// `completeness` is what `SizeCalculator` could not read while sizing the
/// rows — a sealed directory, a stopped walk. `unavailableSources` is a whole
/// evidence mechanism the sweep never had, such as Homebrew not being
/// installed. Conflating them would misstate which kind of gap it is.
public struct UninstallReport: Sendable {
    public let rows: [UninstallRow]
    public let completeness: ScanCompleteness
    public let unavailableSources: [String]

    /// Bytes a receipt declares for a package no identity this sweep
    /// assembled claims, **and** that no assembled row already attributes
    /// through any of its four output categories (`items`, `retained`,
    /// `disclosedOutsideAllowlist`, `refusedByPathGuard`).
    ///
    /// The second clause is load-bearing: package ids and bundle ids are
    /// separate namespaces, so a receipt routinely fails the package-id match
    /// while its declared paths are claimed by a live app through container or
    /// shelf evidence. Counting those bytes here as well as in that app's row
    /// would double them.
    public let unattributedBytes: Int64

    /// `PathGuard` refusals met while building `.deadArtifact` rows — a
    /// candidate dead artifact that sits under `~/Library/LaunchAgents` or a
    /// discovered `NativeMessagingHosts` root and that `PathGuard` refuses
    /// anyway — most often a root-owned, pkg-installed LaunchAgent plist.
    /// Stored rather than computed: unlike an app row's own refusals, nothing
    /// else on this report carries it for a computed property to read back.
    public let deadArtifactGuardRefusals: [DisclosedPath]

    public init(
        rows: [UninstallRow], completeness: ScanCompleteness,
        unavailableSources: [String], unattributedBytes: Int64,
        deadArtifactGuardRefusals: [DisclosedPath]
    ) {
        self.rows = rows
        self.completeness = completeness
        self.unavailableSources = unavailableSources
        self.unattributedBytes = unattributedBytes
        self.deadArtifactGuardRefusals = deadArtifactGuardRefusals
    }

    /// Every `PathGuard` refusal this sweep met, from either source that can
    /// produce one: an app row's own `refusedByPathGuard`, and a dead
    /// artifact `PathGuard` refused before it could become a row at all
    /// (`deadArtifactGuardRefusals`).
    ///
    /// The app-row half is computed, never stored: a stored field can drift
    /// out of agreement with the rows it summarizes. A refusal inside the
    /// allowlist must be disclosed rather than dropped, and this is where the
    /// per-app disclosures surface at report level, unioned with the one class
    /// of refusal that has no row of its own.
    public var pathGuardRefusals: [DisclosedPath] {
        let fromRows = rows.flatMap { row -> [DisclosedPath] in
            guard case .app(let footprint) = row else { return [] }
            return footprint.refusedByPathGuard
        }
        return fromRows + deadArtifactGuardRefusals
    }
}

/// What stage the sweep is in, for a caller that wants to show progress.
/// Deliberately thin — this engine has no per-file progress the way a
/// recursive disk walk does; a caller wanting finer feedback than "which
/// identity is being assembled right now" has nothing more granular to ask
/// for.
public enum UninstallPhase: Sendable, Equatable {
    case assembling(bundleID: String)
    case scanningForDeadArtifacts
}

/// Runs `FootprintAssembler` across every app identity this machine's disk
/// scan found, and folds the result into one report.
///
/// "Every identity" means `InstalledApps.byID` — every bundle the disk scan
/// found — never a guess at identities it did not enumerate. Inferring an
/// absent identity from a bare directory name is the orphan detection this
/// feature exists to replace; that wider sweep is a known gap, not
/// something this coordinator does.
///
/// Dead artifacts are found independently of any identity, by walking
/// `~/Library/LaunchAgents` and every discovered `NativeMessagingHosts` root
/// and classifying each manifest with `DependencyProbe`. Not routed through
/// `FootprintAssembler`: its allowlist has no `LaunchAgents` entry, and a
/// messaging-host manifest only joins a footprint when its declared target
/// resolves inside that bundle — which a dead artifact can never do.
///
/// `unattributedBytes` covers one provable case: a receipt whose package id
/// matches no assembled identity, narrowed to exclude any path an assembled
/// row already attributes. The wider "which bytes belong to no identity at
/// all" sweep would need the identity-from-name inference this design
/// refuses.
public actor UninstallCoordinator {
    /// This app's own bundle id, excluded from every sweep.
    ///
    /// Read from `Bundle.main` rather than hardcoded, so a fork that changes
    /// the identifier — which `TRADEMARKS.md` requires it to — excludes
    /// itself rather than excluding the original. Falls back to the shipped
    /// id when there is no main bundle identifier to read, which is the case
    /// in a test runner.
    let selfBundleID: String

    public init(selfBundleID: String? = nil) {
        self.selfBundleID = selfBundleID
            ?? Bundle.main.bundleIdentifier
            ?? "com.jgabrielrowe.devdrivecacheclean"
    }

    /// The one evidence source this coordinator can currently detect as
    /// missing outright, named for `unavailableSources`. `ReceiptStore` and
    /// the shelf-shaped `FootprintSource`s degrade silently by design (an
    /// unreadable directory is a normal state, not a signal) and so have no
    /// boolean "did this source even exist" to report — `CaskIndex.load`
    /// is the one production entry point in this feature that already
    /// distinguishes "absent" from "empty" via `nil`.
    static let homebrewCaskCacheSourceName = "Homebrew cask cache"

    /// The other Homebrew evidence source the recovery depends on:
    /// the Caskroom listing (`RecoveredIdentities.installedCaskTokens`),
    /// distinct from the cask cache above. `nil` from that probe means
    /// neither known Caskroom prefix could be read at all — named
    /// separately here because a missing Caskroom and a missing cask cache
    /// are two different gaps in what this sweep could evidence, and the rule    /// 28 requires disclosing this one rather than silently recovering
    /// zero cask identities.
    static let homebrewCaskroomSourceName = "Homebrew Caskroom"

    /// Assembles every installed identity's footprint, sweeps for dead
    /// artifacts, and reports what evidence was missing along the way.
    ///
    /// `installedApps`, `receipts`, `receiptsReadable`, `caskIndex` and
    /// `caskroomTokens` are lazily-invoked providers rather than eager
    /// defaults. A Swift default argument is evaluated at the call site,
    /// before the call hops to this actor, so eager defaults would run a
    /// `/Applications` walk, two receipt-directory listings, a cask-cache
    /// parse and a Caskroom listing synchronously on the caller's executor —
    /// typically the main actor. `environment` stays a plain default because
    /// `.live()` only builds a URL, with no I/O.
    public func run(
        installedApps: @Sendable () -> InstalledApps = { InstalledApps.scan() },
        environment: ScanEnvironment = .live(),
        // Returns the completeness of the read beside the receipts, because
        // the two are one fact about one pass and separating them is how a
        // short read gets reported as a whole one. A plist that will not parse
        // is dropped from the array with nothing in the array to show for it.
        receipts: @Sendable () -> (receipts: [Receipt], fullyRead: Bool) = {
            ReceiptStore.read(in: URL(fileURLWithPath: "/var/db/receipts"))
        },
        // Beside `receipts` and never folded into it: `receipts` returns an
        // empty array both for a database that was read and holds nothing and
        // for one that could not be opened, and the presence context below
        // needs those apart. Distinct from that read's `fullyRead`, which
        // answers a different question — whether everything inside a database
        // that *did* open could be parsed.
        receiptsReadable: @Sendable () -> Bool = {
            ReceiptStore.canEnumerate(URL(fileURLWithPath: "/var/db/receipts"))
        },
        caskIndex: @Sendable () -> CaskIndex? = { CaskIndex.loadFromDefaultCache() },
        caskroomTokens: @Sendable () -> Set<String>? = { RecoveredIdentities.installedCaskTokens() },
        appFilenamesOutsideScanRoots: @Sendable () -> (filenames: Set<String>, fullyRead: Bool) = {
            InstalledApps.bundleFilenames(directlyUnder: InstalledApps.presenceOnlyRoots())
        },
        applicationGroups: @Sendable (URL) -> Set<String>? = EntitlementReader.applicationGroups,
        isRunning: @Sendable (String) -> Bool = { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        },
        receiptPaths: @Sendable (Receipt) -> [String]? = ReceiptStore.paths(of:),
        onPhase: @Sendable (UninstallPhase) -> Void = { _ in }
    ) async -> UninstallReport {
        // Invoked here, on this actor's own executor — see the doc comment
        // above for why these are providers rather than eager values.
        let installedApps = installedApps()
        let receiptRead = receipts()
        let receipts = receiptRead.receipts
        let caskIndex = caskIndex()
        let caskroomTokens = caskroomTokens()
        let outsideScanRoots = appFilenamesOutsideScanRoots()

        // Built once per sweep, not once per identity: `assemble` runs
        // 100-150 times and none of these inputs depends on the identity
        // being asked about — the same reason the shelf and messaging-host
        // snapshots exist.
        let caskPresence = caskIndex.map { index in
            CaskPresence.resolve(
                index: index,
                // The filenames the disk walk found, NOT the ones `byID`
                // could be keyed by. `InstalledApps.scan` is
                // partial-tolerant: a bundle whose `Info.plist` cannot be
                // read is skipped when `byID` is built while the bundle sits
                // there on disk, so a `byID`-derived set would call that
                // product's cask provably absent and release the vendor
                // directory it is still using. A cask matches on a bundle
                // filename, which the walk knows whatever the plist said, so
                // sourcing it from discovery removes that error rather than
                // trying to detect it.
                //
                // Unioned with a shallow sweep of the places a bundle can sit
                // without the scan roots ever seeing it — `/opt`,
                // `/Users/Shared`, an external volume. A bundle there is in
                // neither `byID` nor `discoveredBundleFilenames`, so its own
                // cask fails its one positive test and is proved absent,
                // releasing a directory the live product still uses. Presence
                // only: adding filenames can only add refusals, and which
                // apps get their own uninstall row is decided by
                // `installedApps` alone, above and below.
                //
                // `nil` when both came back empty: the enumeration itself
                // found nothing, which proves nothing about any cask.
                installedAppFilenames: {
                    let filenames = installedApps.discoveredBundleFilenames
                        .union(outsideScanRoots.filenames)
                    return filenames.isEmpty ? nil : filenames
                }(),
                // Emptiness is not the only way this enumeration can fail to
                // answer, and it is the rarer one: a sweep root abandoned on a
                // stalled mount leaves the union short while the scan roots
                // keep it non-empty, so the set above looks complete and every
                // cask whose app sat on that mount reads as proved absent. The
                // flag is what keeps a short sweep from releasing that
                // product's paths.
                //
                // Both halves of the union have to have read whole, because
                // either one being short leaves the union short: the scan
                // drops a subtree it cannot list, and the sweep drops a root
                // that will not answer. Neither is visible in the set itself.
                installedAppFilenamesFullyRead:
                    installedApps.discoveredBundleFilenamesFullyRead
                    && outsideScanRoots.fullyRead,
                // `nil` when the receipt database could not be read at all,
                // which `ReceiptStore.receipts(in:)` cannot express: it
                // returns an empty array for an unreadable directory and for
                // a genuinely empty one alike. Those mean opposite things
                // here — a read, empty database proves a pkgutil-only cask
                // absent, an unreadable one proves nothing — and collapsing
                // them marks every such cask absent on a machine that simply
                // could not look.
                receiptPackageIDs: receiptsReadable()
                    ? Set(receipts.map(\.packageID)) : nil,
                // A database that opened can still be short: one plist inside
                // it that will not parse drops its receipt from the set above
                // with nothing there to say so, and a `pkgutil` pattern that
                // would have matched it misses instead — proving a live
                // product absent. The ids are kept either way, because a match
                // in a short set is still a match.
                receiptPackageIDsFullyRead: receiptRead.fullyRead,
                caskroomTokens: caskroomTokens)
        }

        let sizing = SizeCompletenessAccumulator()
        let measure: @Sendable (URL) -> Int64 = { sizing.measure(at: $0) }

        let claimants = ClaimantIndex.build(
            installedApps: installedApps, environment: environment, receipts: receipts,
            // Deferred, same as `unattributedBytes`'s own scope note: no
            // production source of known-but-non-enumerable shared paths
            // exists yet (the report records this as unresolved, not
            // this coordinator's to invent).
            nonEnumerableSharedPaths: [], applicationGroups: applicationGroups)

        let installedIdentities = installedApps.byID.values
            // A bundle inside another bundle is not a separate install: on a
            // real machine 161 of 425 discovered apps were nested helpers.
            // Filtered here rather than in `scan`, because `installedApps.byID`
            // is what `ClaimantIndex` asks "is this app still installed?", and
            // narrowing that would release shared paths a helper still claims.
            // Fewer rows, never fewer claimants.
            .filter { !InstalledApps.isNestedInsideAnotherBundle($0.bundleURL) }
            // DDCC does not offer to uninstall DDCC. Removing the running
            // binary out from under itself is not a supported act, and a
            // cleaning tool listing itself among the things to clean reads as
            // a bug whatever it does next.
            .filter { $0.bundleID != selfBundleID }
            .map { app in
                BundleIdentity(
                    bundleID: app.bundleID, displayName: app.displayName,
                    bundleURL: app.bundleURL, isPresent: true)
            }

        // Identities recoverable from evidence for an app already
        // gone from disk — a receipt's packageID, a cask's declared `app`.
        // `installedApps` passed here is the same, unwidened value passed to
        // `ClaimantIndex.build` above: a recovered identity is never folded
        // into it, so it can never enter that index's entitlement-derived
        // claimant sets.
        let recoveredIdentities = RecoveredIdentities.recover(
            installed: installedApps, receipts: receipts, caskIndex: caskIndex,
            caskroomTokens: caskroomTokens, environment: environment)

        let identities = (installedIdentities + recoveredIdentities)
            .sorted { $0.bundleID < $1.bundleID }

        // A cask-recovered identity carries a synthetic `bundleURL` — a
        // location no bundle was ever at, kept only so the app-anchored cask
        // lookup has a filename. Passing the real `applicationGroups` through
        // would let group-container discovery treat that path as a real bundle
        // and fold a shared container's claim into a row with no entitlement
        // backing it. An absent identity gets the closed answer, so it can
        // never vouch for a shared path.
        //
        // Not the only line holding that property: an identity with no bundle
        // at all — a receipt-recovered one, or a receipt-anchored cask, which
        // is present — has `bundleURL: nil`, and
        // `discoverGroupContainerEvidence` returns `[]` for it whichever
        // closure it is handed.
        let noApplicationGroups: @Sendable (URL) -> Set<String>? = { _ in [] }

        // Read once, for every identity and the dead-artifact sweep alike:
        // neither answer depends on which identity is asked about, and
        // `assemble` runs once per identity, 100-150 times on a real machine.
        // The messaging-host walk is the expensive one — `Application Support`
        // to five levels, thousands of directories, plus a parse of every
        // manifest found.
        let manifests = MessagingHostSource.snapshot(under: environment.applicationSupportURL)
        let shelves = ShelfSource.snapshot(of: environment)
        let evidenceSources = Self.evidenceSources(shelves: shelves, manifests: manifests)

        var rows: [UninstallRow] = []
        rows.reserveCapacity(identities.count)
        var wasCancelled = false
        for (index, identity) in identities.enumerated() {
            // Without this, a cancelled sweep still assembles every
            // remaining identity: `SizeCalculator` checks cancellation and
            // returns `.cancelled`, but the walk around it does not, so
            // Stop would take as long as letting the sweep finish. The
            // identities never reached are counted as unmeasured — a
            // stopped run that rendered as exact would be asserting a
            // completeness it never checked, which is the one thing
            // `ScanCompleteness` exists to prevent.
            if Task.isCancelled {
                wasCancelled = true
                sizing.noteUnmeasured(identities.count - index)
                break
            }
            onPhase(.assembling(bundleID: identity.bundleID))
            let footprint = FootprintAssembler.assemble(
                identity: identity, installedApps: installedApps, environment: environment,
                claimants: claimants, receipts: receipts, caskIndex: caskIndex,
                caskPresence: caskPresence,
                evidenceSources: evidenceSources,
                applicationGroups: identity.isPresent ? applicationGroups : noApplicationGroups,
                isRunning: isRunning,
                receiptPaths: receiptPaths, measure: measure)
            rows.append(.app(footprint))
        }

        // The dead-artifact sweep is its own walk, so a run stopped during
        // the identity loop must not go on to do it. Counted as a single
        // unmeasured unit rather than a per-artifact figure: nothing was
        // enumerated, so there is no count to give — and the number this
        // has to move is `isExact`, not a total.
        let dead: (items: [FootprintItem], guardRefusals: [DisclosedPath])
        if wasCancelled || Task.isCancelled {
            sizing.noteUnmeasured(1)
            dead = ([], [])
        } else {
            onPhase(.scanningForDeadArtifacts)
            dead = Self.deadArtifacts(
                in: environment, manifests: manifests.manifests, measure: measure)
        }
        for item in dead.items {
            rows.append(.deadArtifact(item))
        }

        var unavailableSources: [String] = []
        if caskIndex == nil {
            unavailableSources.append(Self.homebrewCaskCacheSourceName)
        }
        if caskroomTokens == nil {
            unavailableSources.append(Self.homebrewCaskroomSourceName)
        }

        let identityBundleIDs = Set(identities.map(\.bundleID))
        let attributedKeys = Self.attributedPathKeys(in: rows)
        let unattributedBytes = Self.unattributedReceiptBytes(
            receipts: receipts, identityBundleIDs: identityBundleIDs, attributedKeys: attributedKeys,
            environment: environment, receiptPaths: receiptPaths, measure: measure)

        return UninstallReport(
            rows: rows, completeness: sizing.completeness,
            unavailableSources: unavailableSources, unattributedBytes: unattributedBytes,
            deadArtifactGuardRefusals: dead.guardRefusals)
    }

    // MARK: - Dead artifacts

    /// Every manifest or plist this process can prove dead, from the two kinds
    /// `DependencyProbe` classifies: LaunchAgent plists in
    /// `~/Library/LaunchAgents`, flat, and native-messaging-host manifests
    /// under every discovered root. Neither walk cares which app the artifact
    /// belonged to — a dead artifact belongs to no live identity, which is what
    /// makes it dead.
    ///
    /// `guardRefusals` carries every candidate `PathGuard` refused before it
    /// could become a `FootprintItem` — see `deadItem`. The same rule binds
    /// this sweep as binds `FootprintAssembler`: a refusal is disclosed, never
    /// silently dropped.
    private static func deadArtifacts(
        in environment: ScanEnvironment,
        manifests: [MessagingHostSource.ClassifiedManifest],
        measure: @Sendable (URL) -> Int64
    ) -> (items: [FootprintItem], guardRefusals: [DisclosedPath]) {
        var items: [FootprintItem] = []
        var guardRefusals: [DisclosedPath] = []

        // The manifests arrive already discovered and already classified —
        // `run` builds that snapshot once and hands the same one to every
        // identity's `MessagingHostSource`, so this sweep repeats neither the
        // walk nor the parse.
        for manifest in manifests {
            guard case .dead(let target) = manifest.state else { continue }
            if let item = deadItem(
                at: manifest.url, target: target, source: .messagingHost,
                environment: environment, measure: measure, guardRefusals: &guardRefusals) {
                items.append(item)
            }
        }

        let agents = (try? FileManager.default.contentsOfDirectory(
            at: environment.launchAgentsURL, includingPropertiesForKeys: nil)) ?? []
        for agent in agents where agent.pathExtension.lowercased() == "plist" {
            guard case .dead(let target) = DependencyProbe.classify(launchAgentAt: agent) else { continue }
            if let item = deadItem(
                at: agent, target: target, source: .launchAgent,
                environment: environment, measure: measure, guardRefusals: &guardRefusals) {
                items.append(item)
            }
        }

        return (items, guardRefusals)
    }

    /// Builds one dead-artifact row, or records a disclosure and returns `nil`
    /// if `PathGuard` refuses the path — the same backstop `FootprintAssembler`
    /// runs, so this coordinator cannot mint an item whose `removability`, always
    /// `.removable`, the guard would not allow.
    ///
    /// A refusal here is ordinary: root ownership fires on a plist a pkg
    /// installer dropped into `~/Library/LaunchAgents`, which the user cannot
    /// remove themselves — exactly why it must be disclosed rather than vanish.
    private static func deadItem(
        at url: URL, target: String, source: EvidenceSource,
        environment: ScanEnvironment, measure: @Sendable (URL) -> Int64,
        guardRefusals: inout [DisclosedPath]
    ) -> FootprintItem? {
        let context = PathGuard.Context(
            scanRoot: environment.libraryURL.deletingLastPathComponent(), declaredPaths: [])
        guard PathGuard.evaluate(url, removability: .removable, in: context) == .allowed else {
            guardRefusals.append(
                DisclosedPath(path: Candidate.normalizedPathKey(for: url), source: source))
            return nil
        }
        return FootprintItem(
            path: url, sizeBytes: measure(url), evidence: .dead(target: target),
            sources: [source], retainedFor: [], claimCaveat: nil, displayName: url.lastPathComponent)
    }

    // MARK: - Unattributed bytes

    /// Every path key any assembled app row already attributes, across all
    /// four of `AppFootprint`'s output categories — `items` and `retained`
    /// carry real bytes that must never be doubled by also appearing in
    /// `unattributedBytes`; `disclosedOutsideAllowlist` and
    /// `refusedByPathGuard` carry none, but a path this sweep already knows
    /// belongs to a live app is not "attributed to nobody currently known"
    /// either way this list is read.
    private static func attributedPathKeys(in rows: [UninstallRow]) -> Set<String> {
        var keys: Set<String> = []
        for row in rows {
            guard case .app(let footprint) = row else { continue }
            for item in footprint.items { keys.insert(item.id) }
            for item in footprint.retained { keys.insert(item.id) }
            for disclosed in footprint.disclosedOutsideAllowlist { keys.insert(disclosed.path) }
            for refused in footprint.refusedByPathGuard { keys.insert(refused.path) }
        }
        return keys
    }

    /// Sums every allowlisted receipt path whose owning package id matches none
    /// of `identityBundleIDs` and that overlaps no key in `attributedKeys` —
    /// exactly, as an ancestor, or as a descendant. Containment rather than
    /// equality, because a receipt's collapse boundary need not line up with
    /// the assembler's.
    ///
    /// The two directions differ. A receipt path *under* an attributed key was
    /// already measured recursively by that key's row, so counting it doubles
    /// it. A receipt path *above* one is an accepted under-report: dropping it
    /// discards sibling bytes that no row claims.
    ///
    /// The allowlist is asserted twice, lexically then at the resolved path,
    /// reusing `FootprintAssembler`'s helpers. This closes the same escape: a
    /// shelf entry symlinked elsewhere leaves a receipt-declared descendant
    /// that is not itself a symlink, passes the lexical check, and would be
    /// measured through the link.
    ///
    /// Deliberately skips `PathGuard`. Nothing here is offered for deletion,
    /// and the count exists to say "this is on disk and nobody known can be
    /// credited with it" — a root-owned receipt path is real and genuinely
    /// unattributed, so guarding it would under-report the number this keeps
    /// honest.
    ///
    /// Survivors collapse to their outermost ancestor before measuring, for the
    /// reason `collapseNested` exists: a BOM naming both `Foo` and `Foo/data`
    /// would otherwise double the total.
    private static func unattributedReceiptBytes(
        receipts: [Receipt], identityBundleIDs: Set<String>, attributedKeys: Set<String>,
        environment: ScanEnvironment, receiptPaths: @Sendable (Receipt) -> [String]?,
        measure: @Sendable (URL) -> Int64
    ) -> Int64 {
        let roots = FootprintAssembler.allowlistedRootKeys(in: environment)
        let resolvedRoots = FootprintAssembler.resolvedAllowlistedRootKeys(in: environment)

        var keys: Set<String> = []
        for receipt in receipts where !identityBundleIDs.contains(receipt.packageID) {
            guard let paths = receiptPaths(receipt) else { continue }
            for path in paths {
                let key = Candidate.normalizedPathKey(for: URL(fileURLWithPath: path))
                guard FootprintAssembler.isWithinAllowlist(key, roots: roots) else { continue }
                guard FootprintAssembler.isWithinAllowlist(
                    FootprintAssembler.resolvedKey(URL(fileURLWithPath: key)), roots: resolvedRoots)
                else { continue }
                keys.insert(key)
            }
        }

        let unclaimed = keys.filter { key in
            !attributedKeys.contains(key)
                && !attributedKeys.contains { $0.hasPrefix(key + "/") }
                && !attributedKeys.contains { key.hasPrefix($0 + "/") }
        }

        let outermost = unclaimed.filter { key in
            !unclaimed.contains { other in other != key && key.hasPrefix(other + "/") }
        }
        return outermost.reduce(Int64(0)) { $0 + measure(URL(fileURLWithPath: $1)) }
    }
}

/// Wraps `SizeCalculator.measure(at:)` for every path this sweep sizes,
/// accumulating what it could not fully read into the raw material for
/// `UninstallReport.completeness`.
///
/// A lock-guarded class rather than an actor: `assemble`'s `measure` parameter
/// is a synchronous closure, so an `async` accumulator would need a `Task`
/// spawned and awaited for every path measured.
private final class SizeCompletenessAccumulator: Sendable {
    private struct State {
        var unreadablePaths: Set<String> = []
        var flooredItems = 0
        var unmeasuredItems = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Sizes `url`, folding whatever `SizeCalculator` could not fully read
    /// into this accumulator's running completeness state.
    ///
    /// `.unmeasurable` — the path exists but its metadata was denied — folds
    /// into `unreadablePaths`, since it is a denial this sweep met even though
    /// nothing below it was walked. `.cancelled` becomes `unmeasuredItems`
    /// instead: nothing was denied, the walk simply never reached it.
    func measure(at url: URL) -> Int64 {
        switch SizeCalculator.measure(at: url) {
        case .measured(let measurement):
            if measurement.partialRead {
                state.withLock { s in
                    s.unreadablePaths.formUnion(measurement.unreadablePaths)
                    s.flooredItems += 1
                }
            }
            return measurement.bytes
        case .unmeasurable:
            state.withLock { s in
                _ = s.unreadablePaths.insert(Candidate.normalizedPathKey(for: url))
            }
            return 0
        case .cancelled:
            state.withLock { $0.unmeasuredItems += 1 }
            return 0
        }
    }

    /// Work this sweep promised and did not do, from outside
    /// `SizeCalculator` — the identities a cancellation stopped it from
    /// assembling at all, and the dead-artifact walk it never started.
    /// Folded into the same field `.cancelled` measurements land in, since
    /// both mean the same thing to a reader: this figure is a floor.
    func noteUnmeasured(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { $0.unmeasuredItems += count }
    }

    var completeness: ScanCompleteness {
        state.withLock { s in
            ScanCompleteness(
                unreadableDirectories: s.unreadablePaths.count,
                flooredItems: s.flooredItems,
                unmeasuredItems: s.unmeasuredItems)
        }
    }
}


extension UninstallCoordinator {

    /// The evidence sources the sweep runs, in one named place.
    ///
    /// `FootprintAssembler.assemble` also has a default for this parameter,
    /// and the two disagreed once: the default gained `DeclaredPayloadSource`
    /// while this list did not, so the tests -- which take the default --
    /// passed while the shipping sweep never consulted the declared table. A
    /// default argument is not a call site, and only this one is.
    static func evidenceSources(
        shelves: ShelfSource.Snapshot, manifests: MessagingHostSource.Snapshot
    ) -> [any FootprintSource] {
        [
            ContainerSource(),
            ShelfSource(snapshot: shelves),
            MessagingHostSource(snapshot: manifests),
            DeclaredPayloadSource(),
        ]
    }
}
