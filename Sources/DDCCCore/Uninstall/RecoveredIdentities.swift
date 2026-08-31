// Sources/DDCCCore/Uninstall/RecoveredIdentities.swift
import Foundation

/// Identities for an app already gone from disk, recovered from evidence
/// the OS or Homebrew already wrote down — never invented from what a bare
/// directory happens to be named.
///
/// the sweep produces one row per identity in `InstalledApps.byID` —
/// every bundle the disk scan (and Launch Services) actually found. An app
/// removed by hand, whose install receipt or Homebrew Caskroom record still
/// remembers it, produces no row there at all, which is the opposite of
/// what a leftovers-first uninstaller is for. This type closes that gap
/// using exactly two authoritative records:
///
/// - A receipt's `packageID` (Rule 1) — the installer's own record of what
///   it put on the machine.
/// - A Caskroom entry — Homebrew's own record of what
///   it installed, **not** its catalog of everything it offers. See
///   `installedCaskTokens` for why the catalog alone is the wrong evidence.
///
/// Never infers an app from a directory name under `~/Library`: that is the
/// orphan-detection mechanism this project measured and deleted (see
/// `UninstallCoordinator` on what "every identity" means here). A receipt or
/// cask names an app; a `Containers` entry names nothing on its own.
public enum RecoveredIdentities {

    /// Every identity a receipt or an installed cask names that `installed`
    /// does not already account for.
    ///
    /// Most are marked `isPresent: false` — the app is gone and only its
    /// records remain. `recoverFromReceiptAnchoredCasks` is the exception, and
    /// deliberately: a matching `pkgutil` receipt is evidence the product is on
    /// this machine, which is the same evidence `CaskPresence` reads to answer
    /// "present". What such an identity lacks is a bundle, not a product, and
    /// `bundleURL: nil` is where it says so.
    ///
    /// `caskroomTokens` is Homebrew's own record of what is actually
    /// installed — `nil` means neither known Caskroom prefix could be read
    /// at all, in which case no cask identity is ever recovered; an empty,
    /// non-nil set means the Caskroom was read and is
    /// genuinely empty. See `installedCaskTokens`.
    ///
    /// `environment` is accepted to match the shape every evidence-facing
    /// call in this feature takes (`FootprintAssembler.assemble`,
    /// `ClaimantIndex.discoverGroupContainerEvidence`); neither of this
    /// type's two mechanisms reads the filesystem to decide whether an
    /// identity exists — that is exactly Rule 1 — so it goes unused today.
    public static func recover(
        installed: InstalledApps,
        receipts: [Receipt],
        caskIndex: CaskIndex?,
        caskroomTokens: Set<String>?,
        environment: ScanEnvironment
    ) -> [BundleIdentity] {
        recoverFromReceipts(installed: installed, receipts: receipts)
            + recoverFromCasks(installed: installed, caskIndex: caskIndex, caskroomTokens: caskroomTokens)
            + recoverFromReceiptAnchoredCasks(caskIndex: caskIndex, receipts: receipts)
    }

    // MARK: - Receipts

    /// One identity per distinct `packageID` among `receipts` that names no
    /// bundle id `installed` recognizes as installed.
    ///
    /// **Rule 2 — never duplicate.** `installed.isInstalled(_:)` is the
    /// union `InstalledApps` exists to provide — the disk scan's `byID`
    /// **and** Launch Services, because Launch Services alone resolved 68
    /// of 733 container entries on the measurement machine (`InstalledApps`'s
    /// own doc comment). A pkg-installed app outside the scan roots
    /// (`/Users/Shared`, `/opt`, another volume) whose `packageID` equals
    /// its `bundleID` would pass a `byID`-only check and be recovered as
    /// `isPresent: false` while genuinely installed — offering that live
    /// app's own containers and preferences as leftovers, and
    /// stripping the one claimant `FootprintAssembler.liveClaimants` would
    /// otherwise credit when deciding whether a shared group container is
    /// still retained. `byID` alone traded a missing recovered row (safe:
    /// over-retention, recoverable later) for a false absent row on a live
    /// app (unsafe: under-retention, not recoverable) — backwards against
    /// this plan's tie-break. `isInstalled` costs a live Launch Services
    /// check per receipt; the correctness this closes is worth it.
    private static func recoverFromReceipts(
        installed: InstalledApps, receipts: [Receipt]
    ) -> [BundleIdentity] {
        var seen: Set<String> = []
        var identities: [BundleIdentity] = []
        for receipt in receipts.sorted(by: { $0.packageID < $1.packageID }) {
            let packageID = receipt.packageID
            // Apple's own namespace is refused here for the same reason
            // every other evidence source in this feature refuses it
            // (`isAppleOwned`, `FootprintSource.swift`) — but the
            // consequence of skipping it is sharper for this caller than
            // for most: `FootprintAssembler.assemble` refuses an
            // Apple-owned identity outright (`.appleOwned`, zero items).
            // If this method recovered one anyway, its packageID would
            // still enter `UninstallCoordinator`'s `identityBundleIDs`,
            // which is exactly what `unattributedReceiptBytes` uses to
            // decide a receipt is "already accounted for" — silently
            // routing an Apple pkg receipt's bytes into a row that reports
            // zero of them, and out of `unattributedBytes` at the same
            // time. That is undisclosed understatement, the one failure
            // this product refuses; skipping recovery here keeps an Apple pkg
            // receipt counted in `unattributedBytes`.
            guard !isAppleOwned(packageID) else { continue }
            guard !installed.isInstalled(packageID) else { continue }
            guard seen.insert(packageID).inserted else { continue }
            identities.append(BundleIdentity(
                bundleID: packageID,
                // Rule 4 — say which namespace the id came from. `bundleID`
                // above is intentionally a *package* id, not a genuine
                // bundle id: `FootprintAssembler`'s own receipt matching
                // (`receipt.packageID == identity.bundleID`,
                // `FootprintAssembler.swift`'s "Receipts are matched on
                // exact package id equal to bundle id" note) needs exactly
                // that value in that field to attribute this receipt's
                // evidence to this row at all — that reuse is required, not
                // incidental. `namespace: .packageID` is the machine-readable
                // record of that fact; `displayName` stays a
                // plain human name rather than doing this field's job.
                displayName: packageID,
                bundleURL: nil,
                isPresent: false,
                namespace: .packageID))
        }
        return identities
    }

    // MARK: - Casks

    /// The two locations Homebrew has ever put a Caskroom — the directory
    /// it actually installs a cask's app into, distinct from
    /// `CaskIndex.defaultCacheURL`'s catalog of every cask Homebrew's API
    /// *offers*. Probing both, rather than only the Apple-silicon default,
    /// matters concretely: measured, this development machine
    /// has no `/opt/homebrew/Caskroom` at all and a **2-entry**
    /// `/usr/local/Caskroom` (`codex`, `gcloud-cli`) — against 7,695 casks
    /// and 3,981 distinct app names in the catalog.
    public static let caskroomRoots: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true),
    ]

    /// Every cask token this machine's Caskroom(s) actually list — a
    /// directory listing, never a `brew` subprocess — or `nil` if neither
    /// known prefix could be read at all (absent, unreadable, not a
    /// directory), which must never be confused with "read, and genuinely
    /// empty."
    ///
    /// `CaskIndex.load`'s own doc comment already says what
    /// it parses: Homebrew's API catalog of every cask it offers — 7,695 of
    /// them, 4,639 with a `zap` stanza, measured on the same machine. That
    /// is not a record of what this user installed. `recoverFromCasks`
    /// intersects the catalog's app-name declarations against this method's
    /// result precisely so recovery is anchored on Homebrew's own install
    /// record, the same evidentiary bar Rule 1 sets for a receipt.
    public static func installedCaskTokens(
        roots: [URL] = caskroomRoots, fileManager: FileManager = .default
    ) -> Set<String>? {
        var tokens: Set<String> = []
        var anyRootReadable = false
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            anyRootReadable = true
            tokens.formUnion(entries.map(\.lastPathComponent))
        }
        return anyRootReadable ? tokens : nil
    }

    /// One identity per distinct app name a cask **actually installed**
    /// (per `caskroomTokens`) declares as an install artifact, for a name
    /// `installed`'s own bundle filenames do not already account for.
    ///
    /// `caskroomTokens == nil` (neither Caskroom prefix could be
    /// read) recovers nothing — never falls back to reasoning over every
    /// token the catalog happens to mention.
    private static func recoverFromCasks(
        installed: InstalledApps, caskIndex: CaskIndex?, caskroomTokens: Set<String>?
    ) -> [BundleIdentity] {
        guard let caskIndex, let caskroomTokens else { return [] }

        // Rule 2 — the same comparison
        // `CaskIndex.zapDeclarations(forAppBundleNamed:presence:)` already uses to
        // decide whether a cask names an installed bundle: a bundle
        // filename, matched whole and never fuzzily, through the one
        // derivation both sides share (`CaskIndex.nameKey`).
        //
        // Case-insensitive because macOS's default filesystem is: the
        // mainline qBittorrent installs as `qbittorrent.app` while the cask
        // declaring it spells the artifact `qBittorrent.app`. Comparing
        // those exactly reads a live app as absent and offers its data as
        // leftovers — the unsafe direction of this type's tie-break, and
        // not recoverable once acted on.
        let installedAppKeys = Set(
            installed.byID.values.map { CaskIndex.nameKey($0.bundleURL.lastPathComponent) })

        // Several casks can declare the same app (measured:
        // `1password`/`1password@beta` both name `1Password.app`) and must
        // not each mint their own row for it — one identity per distinct
        // app name, the lowest token sorting first only to make which
        // token gets recorded deterministic across runs. Narrowed to
        // Caskroom-listed tokens *before* this collapse, so a catalog-only
        // token can never be the one recorded as the recovering cask.
        // Keyed by `nameKey` rather than by the declared spelling, so two
        // casks naming the same app in different case collapse to one row
        // the way `1password`/`1password@beta` already do. The declared
        // spelling is carried alongside because it, not the key, is what a
        // reader is shown and what `bundleURL` is built from.
        var declaredByKey: [String: (token: String, appName: String)] = [:]
        for (token, appName) in caskIndex.declaredApps() where caskroomTokens.contains(token) {
            let key = CaskIndex.nameKey(appName)
            if let existing = declaredByKey[key], existing.token <= token { continue }
            declaredByKey[key] = (token, appName)
        }

        var identities: [BundleIdentity] = []
        for key in declaredByKey.keys.sorted() {
            guard !installedAppKeys.contains(key) else { continue }
            let (token, appName) = declaredByKey[key]!
            let strippedName = appName.hasSuffix(".app") ? String(appName.dropLast(4)) : appName

            identities.append(BundleIdentity(
                bundleID: token,
                // Rule 4, the cask side. A cask record carries no bundle id
                // at all — only a token and an installed `.app` filename —
                // so there is no genuine bundle id to reuse the way the
                // receipt side reuses a package id. `bundleID` holds the
                // token because `FootprintAssembler`'s cask evidence
                // gathering never reads it (that match is keyed on
                // `identity.bundleURL?.lastPathComponent`, set below);
                // `namespace: .caskToken` is the machine-readable record of
                // that fact, and `displayName` stays the plain
                // app name rather than doing this field's job.
                displayName: strippedName,
                // Rule 3 — a synthetic location, never a guess at where the
                // app actually lived. `bundleURL` exists here only so
                // `FootprintAssembler.caskAnchor`'s app-anchored lookup
                // (`identity.bundleURL?.lastPathComponent`) has a filename to
                // key on: unlike the receipt-anchored arm below, these casks DO
                // declare an `app` artifact, so that is the anchor that reaches
                // them. Rooting it under a path that can never exist on a real
                // machine is what stops it being mistaken for a real bundle by
                // a reader that guessed `/Applications/<name>` instead.
                //
                // What actually guarantees no phantom is offered here is the
                // existence check in `FootprintAssembler.appBundleOutcome`, not
                // this path's spelling and not `isPresent`: the two readers of
                // `bundleURL` that touch the filesystem are that one, which
                // refuses a path nothing sits at, and
                // `ClaimantIndex.discoverGroupContainerEvidence`, whose
                // entitlement read returns nothing for a path with no
                // `Info.plist`. Neither depends on the prefix being this
                // particular unreachable one.
                bundleURL: URL(fileURLWithPath: "/nonexistent/recovered-from-cask", isDirectory: true)
                    .appendingPathComponent(appName, isDirectory: true),
                isPresent: false,
                namespace: .caskToken))
        }
        return identities
    }

    // MARK: - Receipt-anchored casks

    /// One identity per cask that declares **no** `app` artifact and whose
    /// `pkgutil` id matches a receipt on this machine.
    ///
    /// Rule 1 holds: the anchor is the installer's own record, not a
    /// directory name. Such a cask is unreachable by every app-shaped query
    /// in this feature — measured, 268 of the 351 casks declaring an
    /// Application Support path with no `app` artifact carry a usable id —
    /// so without this arm their declared knowledge is inert.
    ///
    /// Deliberately not narrowed against `installed`: a cask with no `app`
    /// artifact has no bundle filename to duplicate, so there is no installed
    /// row for it to collide with.
    ///
    /// Unlike the other two arms this one mints a **present** identity. See
    /// `isPresent` at the construction below for why, and `bundleURL` beside it
    /// for the fact that separates them.
    private static func recoverFromReceiptAnchoredCasks(
        caskIndex: CaskIndex?, receipts: [Receipt]
    ) -> [BundleIdentity] {
        guard let caskIndex else { return [] }
        let packageIDs = Set(receipts.map(\.packageID))
        let appTokens = Set(caskIndex.declaredApps().map(\.token))

        var identities: [BundleIdentity] = []
        for token in caskIndex.allTokens().sorted() where !appTokens.contains(token) {
            var matched = false
            for pattern in caskIndex.receiptPatterns(forCaskToken: token) {
                // Anchored at compile time, not by comparing match range to
                // the whole string — the same reasoning, and the same
                // spelling, as `CaskPresence.resolve`: `firstMatch` finds the
                // leftmost alternative that matches anywhere, so `a|ab`
                // against "ab" can match just "a" and a range-comparison
                // check would reject it even though the pattern as a whole
                // is satisfiable end-to-end. Wrapping in `^(?:...)$` makes
                // the anchors part of what has to match. An uncompilable
                // pattern contributes nothing rather than throwing or
                // falsely matching.
                guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$")
                else { continue }
                matched = packageIDs.contains { id in
                    let range = NSRange(id.startIndex..<id.endIndex, in: id)
                    return regex.firstMatch(in: id, options: [], range: range) != nil
                }
                if matched { break }
            }
            guard matched else { continue }

            identities.append(BundleIdentity(
                bundleID: token,
                displayName: token,
                // No bundle, and no stand-in for one. These casks declare no
                // `app` artifact, so there is no filename for the app-anchored
                // cask lookup to key on and none is needed:
                // `FootprintAssembler.caskAnchor` reaches a `.caskReceipt`
                // identity by its token (`holdsCaskToken`), which is the whole
                // reason that branch exists. A synthetic path here would be a
                // location the assembler and the deletion service could be
                // asked to act on; `nil` cannot be.
                bundleURL: nil,
                // Present, because a matching `pkgutil` receipt is the
                // installer's own record that this product is on the machine —
                // the same record `CaskPresence` reads to answer the same
                // question. Marking it absent described a live pkg-installed
                // product as leftovers and left the two readers of one receipt
                // contradicting each other. What is missing is a bundle, said
                // above; `isPresent` does not say that, and nothing downstream
                // now asks it to.
                isPresent: true,
                // `.caskReceipt`, not `.caskToken`: the identifier is a cask
                // token either way, but the evidence here is the receipt this
                // arm anchored on. The Caskroom is never read, so a row that
                // said it was would state a source no one consulted.
                namespace: .caskReceipt))
        }
        return identities
    }
}
