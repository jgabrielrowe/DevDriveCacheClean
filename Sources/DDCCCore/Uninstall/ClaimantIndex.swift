// Sources/DDCCCore/Uninstall/ClaimantIndex.swift
import Foundation

/// What universe of installed software a `Claim`'s `claimants` set was checked
/// against. A separate axis from `Claim.isEnumerable`, and easily conflated with
/// it: `isEnumerable` says the claim *mechanism* is closed (an OS grant, an
/// authoritative database — never a naming guess), while `population` says what
/// that mechanism was run over. A `Claim` can be `isEnumerable: true` and still
/// miss a genuine claimant that falls outside `population` — see
/// `.scannedInstalledApps` below.
public enum ClaimPopulation: Sendable, Equatable {

    /// Checked against every app the disk scan found a real bundle for, not
    /// every app installed. An app known only to Launch Services, outside the
    /// scan's roots, has no `bundleURL` and no entitlement this file can read.
    /// So "zero remaining claimants among apps we could open" is a narrower
    /// claim than "zero remaining claimants on this machine", and a caller
    /// treating `isEnumerable: true` as a green light must know which it has.
    case scannedInstalledApps

    /// Checked against every receipt `ReceiptStore.paths(of:)` could
    /// actually parse in one `build(...)` call. Complete for pkg installs
    /// **only** when every receipt passed in parsed successfully — see
    /// `build`'s own doc for why a single refused receipt downgrades every
    /// receipt-derived claim in that build to `.unresolvable` rather than
    /// silently leaving the rest at `true`.
    case receiptDatabase

    /// No population was checked at all: either a caller-supplied
    /// known-non-enumerable path, or a receipt-derived claim downgraded
    /// because some other receipt in the same build refused to parse. Always
    /// paired with `isEnumerable: false`.
    case unresolvable
}

/// One shared resource's claim status: who claims it, whether that claim
/// mechanism is trustworthy, and what population it was actually checked
/// against.
///
/// `claimants` holds bundle identifiers (group containers) or package
/// identifiers (receipts) — whatever identity the mechanism that produced
/// this claim actually enumerates.
///
/// `isEnumerable` says the mechanism is closed — an OS grant or an
/// authoritative database, never a naming convention — so a reported claimant
/// was checked rather than guessed. It does not say `claimants` covers every
/// app on the machine; that is `population`'s job, and the two are read
/// together. `false` means the mechanism cannot prove completeness, and
/// `claimants` is never exhaustive whatever `population` says.
public struct Claim: Sendable, Equatable {
    public let path: String
    public let claimants: Set<String>
    public let isEnumerable: Bool
    public let population: ClaimPopulation

    public init(path: String, claimants: Set<String>, isEnumerable: Bool, population: ClaimPopulation) {
        self.path = path
        self.claimants = claimants
        self.isEnumerable = isEnumerable
        self.population = population
    }
}

/// Which installed apps claim a shared resource, in both directions.
///
/// A shared resource is retained while any other installed app still uses it,
/// its bytes stay out of the headline figure until then, and the last app
/// removed collects it. `discoverGroupContainerEvidence` answers "which group
/// containers does this app claim?", growing that app's own footprint;
/// `claim(for:)` and `remainingClaimants(of:afterRemoving:)` answer "which
/// other apps claim this path?", deciding whether its bytes are safe to count.
///
/// Claimants come from entitlements, not names. Stripping a team-id prefix is a
/// naming convention that fails: `6LVTQB9699.com.seriflabs` strips to
/// `com.seriflabs`, which is nobody's bundle id, while the Affinity apps are
/// `com.seriflabs.<product>`. The promise lives in the
/// `com.apple.security.application-groups` entitlement, which `EntitlementReader`
/// reads, so every claimant reported is one the OS attested has access.
///
/// Bundle-id shelves need no entry: `ShelfSource` matches by exact bundle id,
/// so a shelf path is single-claimant by construction.
///
/// Everything else is `isEnumerable: false` rather than dropped. Word and Excel
/// both write into `Application Support/Microsoft` and neither declares it
/// anywhere readable. Such paths arrive through `nonEnumerableSharedPaths`,
/// required so it cannot be omitted and read as "nobody claims this"; the claim
/// is then honest — population unresolvable, and a claimant set that removing
/// apps one at a time can never exhaust.
public struct ClaimantIndex: Sendable {

    /// Recorded as the sole claimant of every `isEnumerable: false` claim
    /// this index constructs directly (non-enumerable paths, and receipt
    /// claims downgraded per `build`'s doc). Never a real bundle id or
    /// package id — its only job is to keep `claimants` non-empty so
    /// `remainingClaimants(of:afterRemoving:)` cannot be emptied out by
    /// subtracting real identifiers one at a time. See that method's doc
    /// comment for why an empty set is exactly the wrong answer for a path
    /// this index cannot fully enumerate.
    static let unresolvableClaimant = "\u{2014} unresolvable claimant (non-enumerable path) \u{2014}"

    private let claimsByPath: [String: Claim]

    fileprivate init(claimsByPath: [String: Claim]) {
        self.claimsByPath = claimsByPath
    }

    /// The claim recorded for `path`, or `nil` if this index has no evidence
    /// connecting `path` to any of its three enumerable mechanisms and no
    /// caller ever flagged it as a known non-enumerable shared path.
    /// `path` is expected to already be a `Candidate.normalizedPathKey(for:)`
    /// result — every path this type stores is one, and this project has
    /// exactly one path-key derivation, so a caller passing anything else
    /// will simply miss.
    public func claim(for path: String) -> Claim? {
        claimsByPath[path]
    }

    /// Who still claims `path` after `bundleID` is removed, or `nil`-safe
    /// empty if `path` carries no claim at all — in which case there is no
    /// retain-until-last question to ask about it in the first place; a
    /// path with no `Claim` is not a shared resource this rule governs.
    ///
    /// For an enumerable claim this is exact set subtraction *within that
    /// claim's population*, not a statement about the whole machine: for a
    /// group container, empty means no scanned app still claims it and says
    /// nothing about an app the scan never reached.
    ///
    /// For a non-enumerable claim, `bundleID` is never subtracted. This index
    /// cannot prove it enumerated every claimant of such a path, so it must not
    /// report zero remaining just because the caller named every app *it* knows
    /// about. Every such claim carries `unresolvableClaimant`, a synthetic
    /// identifier no removal can name, so the result is non-empty by
    /// construction and "we ran out of apps to ask" can never be read as "we
    /// proved nobody else claims this".
    public func remainingClaimants(of path: String, afterRemoving bundleID: String) -> Set<String> {
        guard let claim = claimsByPath[path] else { return [] }
        guard claim.isEnumerable else { return claim.claimants }
        return claim.claimants.subtracting([bundleID])
    }
}

extension ClaimantIndex {

    /// Builds the index from the three enumerable mechanisms, plus paths the
    /// caller already knows are shared but not enumerable.
    ///
    /// `receipts` and `nonEnumerableSharedPaths` carry no default, so omitting
    /// them is a compile error rather than an index where every such path reads
    /// as "nobody claims this".
    ///
    /// Group containers: every installed app's declared group ids become path
    /// keys under `environment.groupContainersURL`, with no existence check —
    /// an app can declare a group whose directory was never created and must
    /// still count as its claimant. No team-id stripping; the entitlement string
    /// already is the directory name.
    ///
    /// Receipts: each receipt's resolved paths become claims keyed by its
    /// package id. `ReceiptStore.paths(of:)` answers `nil` rather than empty so
    /// unreadable is never read as "installed nothing".
    ///
    /// One unreadable bundle signature downgrades every group-container claim
    /// in the build to non-enumerable, and one unparseable receipt does the same
    /// to every receipt-derived claim. All-or-nothing because there is no way to
    /// tell which paths the unreadable one would have named. Losing a claimant
    /// is the hazard, not inventing one: reading "could not be read" as
    /// "claims nothing" releases a shared container while a rival still uses it.
    ///
    /// Non-enumerable paths are recorded with the synthetic
    /// `unresolvableClaimant`, unless the path already has an enumerable claim —
    /// an enumerable answer always wins.
    public static func build(
        installedApps: InstalledApps,
        environment: ScanEnvironment,
        receipts: [Receipt],
        nonEnumerableSharedPaths: Set<String>,
        applicationGroups: @Sendable (URL) -> Set<String>? = EntitlementReader.applicationGroups
    ) -> ClaimantIndex {
        var groupClaimants: [String: Set<String>] = [:]
        var anyBundleUnreadable = false
        for app in installedApps.byID.values {
            guard let groups = applicationGroups(app.bundleURL) else {
                anyBundleUnreadable = true
                continue
            }
            for groupID in groups {
                let path = Candidate.normalizedPathKey(
                    for: environment.groupContainersURL.appendingPathComponent(groupID, isDirectory: true))
                groupClaimants[path, default: []].insert(app.bundleID)
            }
        }

        var claimsByPath: [String: Claim] = [:]
        for (path, claimants) in groupClaimants {
            if anyBundleUnreadable {
                claimsByPath[path] = Claim(
                    path: path, claimants: claimants.union([ClaimantIndex.unresolvableClaimant]),
                    isEnumerable: false, population: .unresolvable)
            } else {
                claimsByPath[path] = Claim(
                    path: path, claimants: claimants, isEnumerable: true, population: .scannedInstalledApps)
            }
        }

        var receiptClaimants: [String: Set<String>] = [:]
        var anyReceiptRefused = false
        for receipt in receipts {
            guard let paths = ReceiptStore.paths(of: receipt) else {
                anyReceiptRefused = true
                continue
            }
            for path in paths {
                receiptClaimants[path, default: []].insert(receipt.packageID)
            }
        }
        for (path, claimants) in receiptClaimants where claimsByPath[path] == nil {
            if anyReceiptRefused {
                claimsByPath[path] = Claim(
                    path: path, claimants: claimants.union([ClaimantIndex.unresolvableClaimant]),
                    isEnumerable: false, population: .unresolvable)
            } else {
                claimsByPath[path] = Claim(
                    path: path, claimants: claimants, isEnumerable: true, population: .receiptDatabase)
            }
        }

        for path in nonEnumerableSharedPaths where claimsByPath[path] == nil {
            claimsByPath[path] = Claim(
                path: path, claimants: [ClaimantIndex.unresolvableClaimant],
                isEnumerable: false, population: .unresolvable)
        }

        return ClaimantIndex(claimsByPath: claimsByPath)
    }

    /// The group container paths `identity` itself claims: each entitlement
    /// group id mapped to `environment.groupContainersURL/<group>`, emitted as
    /// an `EvidenceItem` where the directory exists.
    ///
    /// `ContainerSource` only matches a group id equal to the app's own bundle
    /// id after stripping a team prefix, so it misses the case this was built
    /// for: `6LVTQB9699.com.seriflabs`, 1.76 GB shared by three Affinity apps,
    /// none of whose bundle id is `com.seriflabs`. Each declared group resolves
    /// independently rather than collapsing to the first.
    ///
    /// Existence is checked here but not in `build`: an `EvidenceItem` describes
    /// something real on disk, while the reverse index still counts a declaring
    /// app as claimant of a path that was never created.
    ///
    /// Returns `[]` for an Apple-owned identity, one with no resolvable bundle,
    /// and one whose signature could not be read. Under-reporting that
    /// identity's own footprint is the direction to fail in; `build` is where an
    /// unreadable signature has to change an answer. `build` also never checks
    /// Apple ownership, deliberately — an Apple app holding a group entitlement
    /// is a real claimant, and counting it keeps the container retained.
    public static func discoverGroupContainerEvidence(
        for identity: BundleIdentity,
        in environment: ScanEnvironment,
        applicationGroups: (URL) -> Set<String>? = EntitlementReader.applicationGroups
    ) -> [EvidenceItem] {
        guard !isAppleOwned(identity.bundleID), let bundleURL = identity.bundleURL else { return [] }

        var items: [EvidenceItem] = []
        for groupID in applicationGroups(bundleURL) ?? [] {
            let containerURL = environment.groupContainersURL.appendingPathComponent(groupID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: containerURL.path) else { continue }
            items.append(EvidenceItem(
                path: Candidate.normalizedPathKey(for: containerURL),
                source: .groupContainer,
                claimedBy: identity.bundleID))
        }
        return items
    }
}
