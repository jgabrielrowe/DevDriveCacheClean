// Sources/DDCCCore/Uninstall/FootprintAssembler.swift
import Foundation
import AppKit

/// Assembles one app's footprint from every evidence source, and is where
/// their individual caveats are either respected or lost.
///
/// Decides no policy about sizes, removes nothing, knows nothing about the UI.
/// It gathers, refuses, resolves claims, dedupes, asserts the allowlist, runs
/// `PathGuard`, and sizes the survivors, in that order.
///
/// `RemovalTier` deliberately does not appear here. A tier answers "what does
/// regenerating this cost?", which is the cache question. An uninstall asks
/// whether a path belongs to the app and whether anyone else still uses it.
///
/// Receipts and casks are consumed directly rather than as `FootprintSource`
/// conformances: a package database and a cask index answer a differently
/// shaped question than "list what is under this identity's shelves".
public enum FootprintAssembler {

    // MARK: - The allowlist

    /// The only directories under `~/Library` an item may be emitted from. A
    /// path outside them is a bug, not a judgment call, and one assertion here
    /// replaces a denylist table that would grow forever.
    ///
    /// Exactly the roots the evidence sources can produce. Deliberately
    /// narrower than what casks declare: real zap stanzas name
    /// `~/Library/LaunchAgents`, `~/Library/Logs` and more, and all are
    /// refused. That understates what an app owns, which is the direction
    /// errors must fall.
    public static let allowlistedRootNames = [
        "Containers",
        "Group Containers",
        "Application Support",
        "Application Scripts",
        "Preferences",
        "Caches",
        "HTTPStorages",
        "Saved Application State",
        "WebKit",
        "Cookies",
    ]

    static func allowlistedRootKeys(in environment: ScanEnvironment) -> [String] {
        allowlistedRootNames.map { name in
            Candidate.normalizedPathKey(
                for: environment.libraryURL.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// The same roots as the filesystem actually resolves them.
    ///
    /// `allowlistedRootKeys` is a lexical answer; `PathGuard` resolves a
    /// candidate's whole ancestor chain before judging it. An allowlist
    /// asserted only on the unresolved string is an invariant the next stage
    /// resolves out from under.
    ///
    /// Resolved with the same expression as the paths compared against it. On
    /// macOS standardize and resolve are not inverses even without symlinks:
    /// `/private/var/folders/X` standardizes back to `/var/folders/X`, so
    /// comparing a resolved path against a lexical root rejects everything.
    /// Resolving both sides with one function makes such quirks cancel.
    static func resolvedAllowlistedRootKeys(in environment: ScanEnvironment) -> [String] {
        allowlistedRootNames.map { name in
            resolvedKey(environment.libraryURL.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// A path key with the whole ancestor chain resolved, spelled exactly as
    /// `PathGuard` spells it (`PathGuard.evaluate` and `Context.init` both use
    /// `standardizedFileURL.resolvingSymlinksInPath()`), so the allowlist and
    /// the guard cannot disagree about where a path is.
    static func resolvedKey(_ url: URL) -> String {
        Candidate.normalizedPathKey(for: url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// A path must be **strictly below** an allowlisted root, never equal to
    /// one: `~/Library/Caches` itself is not any app's property.
    static func isWithinAllowlist(_ key: String, roots: [String]) -> Bool {
        roots.contains { key.hasPrefix($0 + "/") }
    }

    /// Recorded in `retainedFor` for a `Group Containers` path that carries
    /// no `Claim` at all.
    ///
    /// `ClaimantIndex.build` records a claim for every group a scanned app's
    /// entitlements declare, so no claim means an entitlement could not be
    /// read — an unsigned bundle, or an app the scan never reached. Absence of
    /// evidence never authorises a reclaim: the cost is over-retention, the
    /// alternative is deleting a container a live app writes to.
    static let unverifiedGroupContainerClaimant =
        "\u{2014} unverified group-container claimants \u{2014}"

    // MARK: - Assembly

    /// Assembles `identity`'s footprint.
    ///
    /// Stage order: gather → assert the allowlist lexically → `PathGuard` →
    /// assert it again at the resolved path → cross-app containment → claim
    /// resolution → collapse nested paths → size. Dedup happens while
    /// gathering, so each unique path is judged once; judging one twice is how
    /// one copy ends up collectable and another retained. The allowlist is
    /// asserted twice because the first pass is lexical and the guard between
    /// them resolves symlinks.
    ///
    /// The allowlist runs before the gates. A dropped path is never
    /// resurrected, so the answer is the same either way, but running
    /// containment over every path a receipt declares computes results that are
    /// then discarded.
    ///
    /// Sources degrade independently: they contribute nothing rather than
    /// throwing, `CaskIndex` is `nil` when Homebrew is absent, and an
    /// unreadable receipt contributes no paths. One unreadable sibling must not
    /// take down the assembly.
    ///
    /// - Parameters:
    ///   - claimants: no default — an empty index reads as "nobody claims
    ///     anything", which is the unsafe answer.
    ///   - caskPresence: no default, unlike its three neighbours, because it
    ///     narrows a safety refusal and must break the build at every call site
    ///     rather than arrive silently. `nil` is a real answer meaning "no
    ///     machine context", leaving the catalogue-wide refusal in place.
    ///   - receiptPaths: injected so tests need not synthesize a binary BOM.
    ///   - isRunning: injected because a test cannot launch an app.
    public static func assemble(
        identity: BundleIdentity,
        installedApps: InstalledApps,
        environment: ScanEnvironment,
        claimants: ClaimantIndex,
        receipts: [Receipt] = [],
        caskIndex: CaskIndex? = nil,
        // No default, deliberately — see the parameter note above.
        caskPresence: CaskPresence?,
        evidenceSources: [any FootprintSource] = [
            ContainerSource(), ShelfSource(), MessagingHostSource(), DeclaredPayloadSource(),
        ],
        applicationGroups: @Sendable (URL) -> Set<String>? = EntitlementReader.applicationGroups,
        isRunning: @Sendable (String) -> Bool = { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        },
        receiptPaths: @Sendable (Receipt) -> [String]? = ReceiptStore.paths(of:),
        measure: @Sendable (URL) -> Int64 = { url in
            SizeCalculator.measure(at: url).measurement?.bytes ?? 0
        }
    ) -> AppFootprint {

        // Apple's namespace is refused even when a caller names one directly.
        // Every source refuses it too; repeated here because cask and receipt
        // paths pass through none of them.
        if isAppleOwned(identity.bundleID) {
            return AppFootprint(
                identity: identity, items: [], retained: [],
                disclosedOutsideAllowlist: [], refusal: .appleOwned)
        }

        // A running app's containers and preferences are open state a live
        // process will rewrite. The refusal is total: a partial footprint of
        // a live app invites removing the half that got through.
        if isRunning(identity.bundleID) {
            return AppFootprint(
                identity: identity, items: [], retained: [],
                disclosedOutsideAllowlist: [], refusal: .appIsRunning)
        }

        var accumulated = gather(
            identity: identity, environment: environment, receipts: receipts,
            caskIndex: caskIndex, caskPresence: caskPresence,
            evidenceSources: evidenceSources,
            applicationGroups: applicationGroups, receiptPaths: receiptPaths)

        // The paths this identity may reach outside the allowlist, derived
        // from the evidence rather than from the source list. Anything carrying
        // `.declaredPayload` was put there by a curated table keyed on this
        // exact bundle id, so the set is empty for every app not in that table
        // and the exemption cannot leak between identities.
        //
        // Read off the accumulated evidence, not by asking the sources what
        // they would declare: only paths that survived gathering -- which means
        // they exist on disk -- can exempt anything.
        let declaredPayloadKeys = Set(
            accumulated.order.filter { key in
                accumulated.byKey[key]?.sources.contains(.declaredPayload) ?? false
            })

        // Stage: assert the allowlist. One funnel, and the only place a path
        // becomes eligible to be an item.
        let roots = allowlistedRootKeys(in: environment)
        var disclosed: [DisclosedPath] = []
        var admitted: [String] = []
        for key in accumulated.order {
            if isWithinAllowlist(key, roots: roots) || declaredPayloadKeys.contains(key) {
                admitted.append(key)
            } else if let claim = accumulated.byKey[key] {
                disclosed.append(DisclosedPath(path: key, source: claim.sources[0]))
            }
        }
        // `PathGuard` runs on every admitted path before anything is
        // collapsed. A path folded into an ancestor never reaches the guard,
        // so folding first would let a symlink or root-owned entry ride along
        // inside the ancestor's recursive size with no verdict.
        let guardContext = PathGuard.Context(
            // The user's home, so the depth rule binds two levels below it,
            // where every allowlisted root's children sit.
            scanRoot: environment.libraryURL.deletingLastPathComponent(),
            // The only bypass this engine grants, and it is granted to exact
            // paths rather than to a rule. A declared payload root is outside
            // the home by definition -- /Users/Shared against /Users/jrowe --
            // so containment alone would refuse it however it was tiered.
            //
            // `PathGuard` checks declaredPaths BEFORE containment but AFTER
            // its existence and root-ownership checks, so a declared path that
            // is a symlink or is owned by root is still refused. The bypass is
            // narrow: it excuses a path from being outside the scan root, and
            // from nothing else.
            declaredPaths: declaredPayloadKeys)

        // The allowlist again, at the resolved location — see below for why
        // this cannot be folded into the funnel above.
        let resolvedRoots = resolvedAllowlistedRootKeys(in: environment)

        var survivors: [String] = []
        var guardRefused: [DisclosedPath] = []
        for key in admitted {
            guard let entry = accumulated.byKey[key] else { continue }
            // `.lockedInformational` counts as a refusal: a privileged row is
            // not something this engine offers, and cannot arise from an
            // allowlisted root anyway.
            let verdict = PathGuard.evaluate(
                URL(fileURLWithPath: key), removability: .removable, in: guardContext)

            // Absence is the one refusal that discloses nothing. Every other
            // reason names bytes that exist and were not touched, which is what
            // the view prints: "this app owns more than what is offered". A
            // path not on disk makes that false.
            //
            // Phantoms come from declared evidence: a cask zap stanza or a
            // receipt names paths an app might create, and a machine has only
            // some of them. Enumerated sources list what is there and cannot
            // produce one.
            if verdict == .refused(reason: PathGuard.doesNotExistReason) {
                continue
            }

            if verdict == .allowed {
                // Re-assert the allowlist on the resolved path.
                //
                // The funnel above is lexical; `PathGuard` is not. It resolves
                // the ancestor chain and checks containment against `scanRoot`,
                // which is the user's home, not the allowlisted roots. So a
                // path whose string sits under `~/Library/Application Support`
                // can be `.allowed` while it really lives in `~/Dropbox`: if
                // that shelf entry is a symlink, the symlink is refused, but a
                // descendant of it is not itself a symlink and nothing else
                // refuses it — it would be emitted, sized through the symlink,
                // and offered at a location no allowlist named. `DeletionService`
                // would not catch it either; it re-runs the guard with no
                // allowlist.
                //
                // Routed to `disclosedOutsideAllowlist` rather than dropped:
                // counted as the app's, never offered. Disclosure carries no
                // size, so it inflates no total.
                //
                // After the verdict rather than in the funnel: asserted earlier
                // it would also re-route the symlink itself, which is refused
                // for being a symlink, not for where it points.
                if isWithinAllowlist(resolvedKey(URL(fileURLWithPath: key)), roots: resolvedRoots)
                    || declaredPayloadKeys.contains(key) {
                    survivors.append(key)
                } else {
                    // Disclosed under the path the evidence named, not the
                    // resolved one: that is the string the user will
                    // recognise, and it is the same key every other output
                    // list uses.
                    disclosed.append(DisclosedPath(path: key, source: entry.sources[0]))
                }
            } else {
                // Disclosed, not dropped. A symlink or root-owned entry
                // under an allowlisted root would otherwise leave the
                // footprint quietly short by its size.
                guardRefused.append(DisclosedPath(path: key, source: entry.sources[0]))
            }
        }

        // Stage: both gates, over every guard survivor, before the
        // collapse, so a path that is about to be folded into an ancestor
        // still gets judged. Gate (b) in particular can only see a foreign
        // immediate child of the path it is asked about; asking only about
        // post-collapse survivors would miss a foreign child of a folded
        // descendant entirely.
        let foreignRetainers = crossAppRetainers(
            keys: survivors, identity: identity, caskIndex: caskIndex,
            caskPresence: caskPresence)

        var verdicts: [String: Verdict] = [:]
        for key in survivors {
            verdicts[key] = retention(
                key: key, identity: identity, claimants: claimants,
                installedApps: installedApps, environment: environment,
                foreignRetainers: foreignRetainers[key] ?? [])
        }

        // Stage: collapse, carrying every folded descendant's verdict up.
        let kept = collapseNested(survivors, in: &accumulated, verdicts: &verdicts)

        var items: [FootprintItem] = []
        var retained: [FootprintItem] = []

        for key in kept {
            guard let entry = accumulated.byKey[key] else { continue }
            let url = URL(fileURLWithPath: key)
            let verdict = verdicts[key] ?? Verdict(retainers: [], caveat: nil)

            let item = FootprintItem(
                path: url,
                sizeBytes: measure(url),
                evidence: entry.deadTarget.map { EvidenceClass.dead(target: $0) }
                    ?? .attributed(entry.sources[0]),
                sources: entry.sources,
                retainedFor: verdict.retainers,
                claimCaveat: verdict.caveat,
                displayName: url.lastPathComponent)

            if verdict.retainers.isEmpty {
                items.append(item)
            } else {
                retained.append(item)
            }
        }

        // The app itself, which no evidence source produces and the allowlist
        // funnel above would refuse: that funnel describes `~/Library`
        // shelves, and the bundle lives in `/Applications`.
        let bundle = appBundleOutcome(for: identity, guardContext: guardContext, measure: measure)
        if let offered = bundle.item { items.append(offered) }
        if let refused = bundle.refusal { guardRefused.append(refused) }

        return AppFootprint(
            identity: identity,
            items: items.sorted(by: bySizeThenPath),
            retained: retained.sorted(by: bySizeThenPath),
            disclosedOutsideAllowlist: disclosed.sorted { $0.path < $1.path },
            refusedByPathGuard: guardRefused.sorted { $0.path < $1.path },
            refusal: nil)
    }

    /// The identity's own `.app` — offered for removal, disclosed as refused,
    /// or absent.
    ///
    /// The bundle is `declaredPaths` rather than allowlisted: the allowlist
    /// names roots under `~/Library`, while the bundle is in `/Applications`,
    /// so containment would refuse it. Declaring the path bypasses containment
    /// and depth and nothing else — a symlink, a volume root, a protected home
    /// child, `/Applications` itself and an absent path are all still refused
    /// before the declaration is consulted.
    ///
    /// Built with the same context the deletion will use. `DeletionService`
    /// re-runs `PathGuard` before removing anything, so offering a bundle under
    /// looser rules would make every offer a promise the deletion breaks.
    ///
    /// A refused bundle is disclosed rather than dropped: an app whose bundle
    /// this engine will not touch is what the user most needs told.
    private static func appBundleOutcome(
        for identity: BundleIdentity,
        guardContext: PathGuard.Context,
        measure: @Sendable (URL) -> Int64
    ) -> (item: FootprintItem?, refusal: DisclosedPath?) {
        // A real bundle on disk is the whole precondition — not `isPresent`.
        // The two are different facts: a pkg-installed product recovered from a
        // receipt is present and has no `.app` at all, while an identity
        // recovered from a cask carries a synthetic location no bundle ever sat
        // at. Neither has anything to remove here.
        //
        // Existence is checked rather than left to `PathGuard`, because
        // `PathGuard` cannot answer it: `isAbsent` needs an existing ancestor
        // to discriminate "gone" from "unreadable", and a path whose every
        // ancestor is missing has none, so it answers `false` and the verdict
        // falls through to `isRootOwned` — which refuses an unstattable path,
        // which `requiresElevation` reads as the one clearable refusal. Without
        // this line that chain offers a deletion at a path nothing is at, and
        // asks for an admin password to perform it.
        //
        // A bundle that vanished between the scan and here yields no item and
        // no disclosure: there is nothing left to offer and nothing left to
        // describe, which is the under-reporting direction.
        guard let bundleURL = identity.bundleURL,
              FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false))
        else { return (nil, nil) }

        let key = Candidate.normalizedPathKey(for: bundleURL)
        let context = PathGuard.Context(
            scanRoot: guardContext.scanRoot, declaredPaths: [key])
        // A pkg-installed app — Word, Excel, Trello — is owned by root, and
        // that is the one refusal the user can clear: Finder performs the
        // Trash move after authenticating. Disclosing it as untouchable would
        // be false, so it becomes an item that says it needs authentication
        // rather than a refusal. Every other refusal is still disclosed and
        // still produces no item.
        var requiresAuthentication = false
        if PathGuard.evaluate(bundleURL, removability: .removable, in: context) != .allowed {
            guard PathGuard.requiresElevation(bundleURL, removability: .removable, in: context)
            else {
                return (nil, DisclosedPath(path: key, source: .appBundle))
            }
            requiresAuthentication = true
        }

        return (
            FootprintItem(
                path: bundleURL, sizeBytes: measure(bundleURL),
                evidence: .attributed(.appBundle), sources: [.appBundle],
                retainedFor: [], claimCaveat: nil, displayName: bundleURL.lastPathComponent,
                requiresAuthentication: requiresAuthentication),
            nil)
    }

    /// One path's retention answer: who still claims it, and what population
    /// that answer was checked against.
    ///
    /// A named type rather than a tuple: it is computed in one stage, merged
    /// across a collapse, and read in another, and a two-element tuple threaded
    /// through that is how the two fields get swapped or dropped.
    struct Verdict {
        var retainers: Set<String>
        var caveat: ClaimPopulation?
    }

    /// The more cautionary of two caveats, for a row merging several paths.
    ///
    /// Ordered by how much qualification the UI owes the user:
    /// `.unresolvable` (no population enumerable), `.scannedInstalledApps`
    /// (only apps the scan reached), `.receiptDatabase` (authoritative). A
    /// merged row inherits the weakest guarantee folded into it; taking the
    /// strongest would let an ancestor launder a descendant's uncertainty.
    static func moreCautionary(_ a: ClaimPopulation?, _ b: ClaimPopulation?) -> ClaimPopulation? {
        func rank(_ population: ClaimPopulation?) -> Int {
            switch population {
            case .none: return 0
            case .receiptDatabase: return 1
            case .scannedInstalledApps: return 2
            case .unresolvable: return 3
            }
        }
        return rank(a) >= rank(b) ? a : b
    }

    /// Drops any guard-surviving path that already has a guard-surviving
    /// ancestor, folding its evidence and retention verdict into that ancestor.
    ///
    /// `SizeCalculator` measures recursively, so an emitted ancestor and
    /// descendant would each contribute the descendant's bytes and
    /// `reclaimableBytes` would count them twice. Receipts are the realistic
    /// trigger: one pkg's BOM yields `Foo`, `Foo/data`, `Foo/sub` and
    /// `Foo/sub/x` as separate paths. Every other judgment here errs toward
    /// retaining, which understates; double-counting overstates, which is the
    /// direction this product cannot absorb.
    ///
    /// The verdict is inherited, not recomputed. Both gates judge a path by
    /// what sits immediately around it, so an ancestor judged on its own terms
    /// has no immediate foreign child — that child belonged to the descendant —
    /// and would be offered whole, shared subtree included. A merged row takes
    /// the union of its folded descendants' retainers and the more cautionary
    /// of their caveats; a pass after the collapse would see nothing there.
    ///
    /// Runs after `PathGuard`. A folded path never reaches the guard, so
    /// collapsing first would let a descendant that would individually be
    /// refused ride inside its ancestor's recursive size with no verdict and no
    /// disclosure. Guarding first also lets descendants of a refused ancestor
    /// survive on their own.
    ///
    /// Sources and any `deadTarget` merge into the kept ancestor, so neither
    /// corroboration nor the stronger `.dead` claim is downgraded. Ancestry is
    /// tested by walking each key's parent chain against the surviving set,
    /// linear in depth rather than quadratic in path count.
    private static func collapseNested(
        _ candidates: [String], in accumulated: inout Accumulated, verdicts: inout [String: Verdict]
    ) -> [String] {
        let candidateSet = Set(candidates)
        var kept: [String] = []
        for key in candidates {
            // The outermost surviving ancestor, not the nearest: every
            // intermediate level folds into the same row, whose recursive size
            // covers them once. Nearest-ancestor folding looks equivalent but
            // is not — order is parent-first, so an intermediate level inherits
            // a deeper retainer only after being folded away, and the retainer
            // never reaches the surviving row.
            var ancestor: String?
            var walk = parentKey(of: key)
            while let current = walk {
                if candidateSet.contains(current) { ancestor = current }
                walk = parentKey(of: current)
            }
            guard let ancestor else {
                kept.append(key)
                continue
            }

            if let child = accumulated.byKey[key] {
                for source in child.sources {
                    accumulated.record(ancestor, source, deadTarget: child.deadTarget)
                }
            }

            // The retention inheritance. Without it this collapse is a
            // data-loss path, not an arithmetic fix.
            let childVerdict = verdicts[key] ?? Verdict(retainers: [], caveat: nil)
            var merged = verdicts[ancestor] ?? Verdict(retainers: [], caveat: nil)
            merged.retainers.formUnion(childVerdict.retainers)
            merged.caveat = moreCautionary(merged.caveat, childVerdict.caveat)
            verdicts[ancestor] = merged
        }
        return kept
    }

    private static func bySizeThenPath(_ a: FootprintItem, _ b: FootprintItem) -> Bool {
        a.sizeBytes == b.sizeBytes ? a.id < b.id : a.sizeBytes > b.sizeBytes
    }

    // MARK: - Gather and dedup

    /// One path's accumulated evidence. `sources` is ordered by first
    /// sighting and never collapsed: two sources agreeing is corroboration,
    /// and dedup that discards the second one throws away the very thing
    /// that makes an attribution strong.
    private struct Accumulated {
        var order: [String] = []
        var byKey: [String: Entry] = [:]

        struct Entry {
            var sources: [EvidenceSource]
            var deadTarget: String?
        }

        mutating func record(_ key: String, _ source: EvidenceSource, deadTarget: String? = nil) {
            if var existing = byKey[key] {
                if !existing.sources.contains(source) { existing.sources.append(source) }
                if existing.deadTarget == nil { existing.deadTarget = deadTarget }
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = Entry(sources: [source], deadTarget: deadTarget)
            }
        }
    }

    private static func gather(
        identity: BundleIdentity,
        environment: ScanEnvironment,
        receipts: [Receipt],
        caskIndex: CaskIndex?,
        caskPresence: CaskPresence?,
        evidenceSources: [any FootprintSource],
        applicationGroups: @Sendable (URL) -> Set<String>?,
        receiptPaths: @Sendable (Receipt) -> [String]?
    ) -> Accumulated {
        var accumulated = Accumulated()

        for source in evidenceSources {
            for evidence in source.evidence(for: identity, in: environment) {
                if case .messagingHost = evidence.source,
                   case .dead(let target) = DependencyProbe.classify(
                       manifestAt: URL(fileURLWithPath: evidence.path)) {
                    // A manifest still pointing at a helper the bundle no
                    // longer contains is provably stale, which is a stronger
                    // claim than merely attributed — `EvidenceClass.dead`
                    // exists so the UI can say so.
                    accumulated.record(evidence.path, evidence.source, deadTarget: target)
                } else {
                    accumulated.record(evidence.path, evidence.source)
                }
            }
        }

        // Group containers whose claim is an entitlement grant rather than a
        // name — the 1.76 GB `6LVTQB9699.com.seriflabs` case that no
        // name-stripping rule can reach. See `ClaimantIndex`'s doc comment.
        for evidence in ClaimantIndex.discoverGroupContainerEvidence(
            for: identity, in: environment, applicationGroups: applicationGroups) {
            accumulated.record(evidence.path, evidence.source)
        }

        // Casks are anchored, never searched: looked up by the bundle's own
        // filename, or by the cask's own token, but never by scanning
        // declarations for a path. An identity with no resolvable bundle has
        // no filename to anchor on and gets no cask evidence at all, rather
        // than a guess.
        if let caskIndex {
            let declarations: [CaskIndex.CaskDeclaredPath]
            switch caskAnchor(for: identity, in: caskIndex) {
            case .caskToken(let token):
                declarations = caskIndex.zapDeclarations(
                    forCaskToken: token, presence: caskPresence)
            case .appBundleName(let bundleName):
                declarations = caskIndex.zapDeclarations(
                    forAppBundleNamed: bundleName, presence: caskPresence)
            case nil:
                declarations = []
            }
            for declaration in declarations {
                accumulated.record(
                    Candidate.normalizedPathKey(for: URL(fileURLWithPath: declaration.path)),
                    .cask(token: declaration.token))
            }
        }

        // Exact package id equal to bundle id. Package identifiers are a
        // separate namespace that merely resembles bundle identifiers, so
        // matching by prefix or vendor component is a naming guess. The cost is
        // real — a pkg whose package id differs contributes nothing — and it is
        // the safe direction.
        for receipt in receipts where receipt.packageID == identity.bundleID {
            for path in receiptPaths(receipt) ?? [] {
                accumulated.record(path, .receipt(packageID: receipt.packageID))
            }
        }

        return accumulated
    }

    /// How a cask query for one identity is anchored. Both cask questions
    /// the assembler asks — what this identity's own casks declare, and
    /// which *other* products declare something beneath a shared root — are
    /// stated in terms of it, so they cannot disagree about who the row is.
    private enum CaskAnchor {
        case caskToken(String)
        case appBundleName(String)
    }

    /// The anchor for `identity`, or `nil` when it has none and so gets no
    /// cask evidence at all rather than a guess.
    ///
    /// A cask that declares no `app` artifact cannot be reached by an
    /// app-shaped lookup at all — that is the whole reason
    /// `RecoveredIdentities` anchored it on a receipt. For those, and only
    /// those, `bundleID` holds the cask token and the query goes by token.
    /// Such an identity carries no `bundleURL` at all, so the app-anchored
    /// query below has nothing to key on and the identity's footprint would
    /// always be empty.
    ///
    /// Every other identity keeps the app-anchored path, including
    /// cask-recovered ones that DO name an app: for those the bundle
    /// filename is a real `app` artifact and switching anchors would change
    /// an answer that is already right.
    private static func caskAnchor(
        for identity: BundleIdentity, in caskIndex: CaskIndex
    ) -> CaskAnchor? {
        // `== false`, not `!`: `declaresApp` withholds with `nil` when it
        // could not read the token's `app` artifacts, and only a cask that
        // provably declares none belongs on the token anchor. A withheld
        // answer keeps the app-shaped path below, which is the retaining
        // direction — see `CaskIndex.declaresApp(forCaskToken:)`.
        if identity.namespace.holdsCaskToken,
           caskIndex.declaresApp(forCaskToken: identity.bundleID) == false {
            return .caskToken(identity.bundleID)
        }
        if let bundleName = identity.bundleURL?.lastPathComponent {
            return .appBundleName(bundleName)
        }
        return nil
    }

    // MARK: - Gate (b): cross-app containment

    /// Which of `keys` another product's cask declaration suggests is a shared
    /// root, and who to name as retaining it.
    ///
    /// `CaskIndex` refuses a path two or more casks declare identically. It
    /// cannot see a path declared by one cask that is an ancestor of a
    /// different product's deeper declaration, because that needs every
    /// product's declarations at once, which only the assembler holds.
    ///
    /// A foreign declaration that is an **immediate child** retains the root;
    /// anything deeper does not. An immediate child partitions the directory
    /// between products, while a deeper path is usually an artifact planted
    /// inside one product's own layout — a native-messaging host inside
    /// Chrome's directory is a Chrome integration and should die with Chrome.
    /// Plain containment would instead refuse Chrome's own directory, because
    /// nine unrelated casks declare paths beneath it.
    ///
    /// A heuristic, not proof of co-tenancy. Safe only because the gate is
    /// additive: it adds retainers and never removes one, so a misfire equals
    /// not having run it. It catches roots that partition flat and misses
    /// roots that partition beneath scaffolding — a sandbox container cannot
    /// partition flat, so those are known false negatives, with
    /// `ClaimantIndex.nonEnumerableSharedPaths` covering the residue. Tuning
    /// the depth threshold does not fix that; depth is not the distinguishing
    /// property.
    private static func crossAppRetainers(
        keys: [String], identity: BundleIdentity, caskIndex: CaskIndex?,
        caskPresence: CaskPresence?
    ) -> [String: Set<String>] {
        // The same anchor `gather` queried this identity's own declarations
        // by. Asking about strangers by a different anchor than the one that
        // selected the row's own paths makes the row a stranger to itself:
        // for a cask with no `app` artifact, an app-name exclusion excludes
        // nothing, and its own deeper declaration returns as another
        // product's claim on its own ancestor.
        guard let caskIndex, let anchor = caskAnchor(for: identity, in: caskIndex)
        else { return [:] }

        var retainers: [String: Set<String>] = [:]
        for key in keys {
            let foreign: [CaskIndex.CaskDeclaredPath]
            switch anchor {
            case .caskToken(let token):
                foreign = caskIndex.foreignDeclarations(
                    below: key, ofCaskToken: token, presence: caskPresence)
            case .appBundleName(let bundleName):
                foreign = caskIndex.foreignDeclarations(
                    below: key, ofAppBundleNamed: bundleName, presence: caskPresence)
            }
            for declaration in foreign {
                let childKey = Candidate.normalizedPathKey(
                    for: URL(fileURLWithPath: declaration.path))
                guard parentKey(of: childKey) == key else { continue }
                retainers[key, default: []].insert(retainerName(for: declaration, childKey: childKey))
            }
        }
        return retainers
    }

    /// Who to name as holding a shared root. The declaring cask's own app
    /// name where it has one; its token otherwise — `bing-wallpaper` and
    /// `microsoft-word` are both real casks with a `zap` stanza and no `app`
    /// artifact at all, and they are exactly the declarations this gate
    /// exists to see.
    private static func retainerName(
        for declaration: CaskIndex.CaskDeclaredPath, childKey: String
    ) -> String {
        if let appName = declaration.appNames.sorted().first { return appName }
        if !declaration.token.isEmpty { return declaration.token }
        return (childKey as NSString).lastPathComponent
    }

    private static func parentKey(of key: String) -> String? {
        guard let slash = key.lastIndex(of: "/"), slash != key.startIndex else { return nil }
        return String(key[key.startIndex..<slash])
    }

    // MARK: - Gate (a): reclaim requires positive confirmation, never an absence

    /// Who still claims `key`, and what population that answer was checked
    /// against.
    ///
    /// `ClaimantIndex` computes group-container claimants from the disk scan,
    /// so an app in `~/Downloads`, `/opt` or on another volume writes into
    /// `~/Library/Group Containers` and contributes no claimant. An empty set
    /// over `.scannedInstalledApps` therefore proves only that no *scanned*
    /// claimant remains, never that the last claimant is gone.
    ///
    /// Before an empty set releases a shared container, the live
    /// Launch-Services-backed `isInstalled(_:)` — not the `byID` snapshot — is
    /// asked about the team-stripped group id and every id previously recorded
    /// as claiming the path. Any positive answer retains. The stripped form
    /// comes from `ContainerSource.strippedGroupID(from:)` so the two
    /// spellings cannot drift.
    ///
    /// A clean negative is still not a green light: the item keeps
    /// `claimCaveat: .scannedInstalledApps`, because an app on an unmounted
    /// volume cannot be enumerated by any question this process can ask.
    ///
    /// Over-retaining costs bytes the user can free later; under-retaining
    /// destroys data with no recovery. Every branch falls toward retain.
    private static func retention(
        key: String,
        identity: BundleIdentity,
        claimants: ClaimantIndex,
        installedApps: InstalledApps,
        environment: ScanEnvironment,
        foreignRetainers: Set<String>
    ) -> Verdict {
        var retainers = foreignRetainers

        guard let claim = claimants.claim(for: key) else {
            // No claim at all. For a group container that is absence of
            // evidence, not evidence of absence. For a bundle-id-exact shelf
            // or a cask path there is no retain-until-last question: two apps
            // cannot both equal one bundle id string.
            if isGroupContainerPath(key, in: environment) {
                retainers.insert(unverifiedGroupContainerClaimant)
            }
            return Verdict(retainers: retainers, caveat: nil)
        }

        let remaining = claimants.remainingClaimants(of: key, afterRemoving: identity.bundleID)
        if !remaining.isEmpty {
            return Verdict(retainers: retainers.union(remaining), caveat: claim.population)
        }

        switch claim.population {
        case .scannedInstalledApps:
            let confirmed = liveClaimants(
                key: key, claim: claim, identity: identity, installedApps: installedApps)
            if !confirmed.isEmpty {
                return Verdict(retainers: retainers.union(confirmed), caveat: claim.population)
            }
            return Verdict(retainers: retainers, caveat: .scannedInstalledApps)

        case .receiptDatabase:
            return Verdict(retainers: retainers, caveat: .receiptDatabase)

        case .unresolvable:
            // Unreachable by construction: every non-enumerable claim carries
            // `unresolvableClaimant`, which no removal subtracts, so
            // `remaining` cannot be empty. Explicit rather than a `default`,
            // because the only way here is someone relaxing that invariant and
            // the safe answer is still retain.
            return Verdict(
                retainers: retainers.union([ClaimantIndex.unresolvableClaimant]),
                caveat: .unresolvable)
        }
    }

    /// The live half of gate (a): identifiers that, if Launch Services
    /// vouches for any of them, veto the reclaim. `identity` itself is
    /// excluded — the app being removed is trivially installed, and
    /// including it would retain every container unconditionally.
    private static func liveClaimants(
        key: String, claim: Claim, identity: BundleIdentity, installedApps: InstalledApps
    ) -> Set<String> {
        var candidates = claim.claimants
        candidates.insert(ContainerSource.strippedGroupID(from: (key as NSString).lastPathComponent))
        candidates.remove(identity.bundleID)
        return candidates.filter { installedApps.isInstalled($0) }
    }

    private static func isGroupContainerPath(_ key: String, in environment: ScanEnvironment) -> Bool {
        key.hasPrefix(Candidate.normalizedPathKey(for: environment.groupContainersURL) + "/")
    }
}
