// Sources/DDCCCore/Uninstall/AppFootprintModels.swift
import Foundation

/// Why a path is in an app's footprint at all.
///
/// `.attributed` carries the evidence source that put it there — a
/// container, a shelf, a receipt, a cask, a messaging-host manifest.
/// `.dead` is the narrower claim `DependencyProbe` can make about a
/// declaration whose target no longer exists: a native-messaging manifest
/// still pointing at a helper inside a bundle that no longer contains it is
/// provably stale, and stale is a stronger statement than merely attributed.
///
/// Kept as an enum rather than an optional flag on the source because the
/// two are not the same kind of claim and a caller should be forced to
/// branch: "this belongs to the app" and "this points at something that is
/// gone" carry different confidence and deserve different words in the UI.
public enum EvidenceClass: Sendable, Equatable {
    case attributed(EvidenceSource)
    case dead(target: String)
}

/// One path in an app's footprint, sized and judged.
///
/// Conforms to `Deletable`, so the one guarded removal path in
/// `DeletionService` can consume these directly — a second implementation of
/// guarded removal is the specific thing this project's design exists to
/// prevent (see `Deletable`).
///
/// **Every item carries `.removable`.** Not because privileges were checked
/// and found unnecessary, but because anything needing them lies outside the
/// allowlisted roots and was refused before it could become an item —
/// `/Library/PrivilegedHelperTools`, `/Applications`, everything a receipt
/// manifest names outside this user's `~/Library`. `PathGuard.evaluate`
/// returns `.lockedInformational` for a `.requiresPrivileges` row, and
/// `FootprintAssembler` treats that verdict as a refusal, so the case is
/// unreachable from two directions rather than one.
public struct FootprintItem: Sendable, Identifiable, Deletable, Equatable {

    /// The normalized path key, which is also the dedup key the assembler
    /// merged this item under. `Candidate.normalizedPathKey(for:)` is this
    /// project's one path-key derivation; deriving an id any other way would
    /// reintroduce the two-spellings-of-one-path bug its doc comment
    /// records.
    public var id: String { Candidate.normalizedPathKey(for: path) }

    public let path: URL
    public let sizeBytes: Int64

    /// The strongest single claim on this path — `.dead` where a
    /// declaration was proved stale, otherwise the first source that found
    /// it, in the assembler's fixed source order.
    public let evidence: EvidenceClass

    /// Every source that independently found this path, deduped and in a
    /// stable order. Two sources agreeing is corroboration, and collapsing
    /// them to one at dedup time would throw away exactly the evidence that
    /// makes an attribution strong enough to act on.
    public let sources: [EvidenceSource]

    /// Who still claims this path, if anyone. Non-empty means the item is
    /// retained: displayed with its size so the user can see the bytes
    /// exist, but excluded from `AppFootprint.reclaimableBytes` and not
    /// deletable. Entries are whatever identity the retaining mechanism
    /// names — a bundle id, a package id, or a foreign product's name from a
    /// cask declaration.
    public let retainedFor: Set<String>

    /// The population a "no remaining claimant" answer was actually checked
    /// against, for an item whose collectability rested on that answer;
    /// `nil` for an item no claim governs.
    ///
    /// `.scannedInstalledApps` is the one that must reach the UI as a
    /// qualification rather than a green light: it means no app *the disk
    /// scan found* still claims this container, and an app on an unmounted
    /// volume stays unenumerable and cannot be closed. The UI must not say
    /// "safe to reclaim" unqualified for a group container carrying this.
    public let claimCaveat: ClaimPopulation?

    public let displayName: String

    /// True only for an app's own `.app` bundle that the guard refuses on
    /// root ownership alone — a pkg-installed app such as Word or Trello.
    /// `DeletionService` moves these to the Trash through Finder, which
    /// authenticates first; every other item is removed directly.
    public let requiresAuthentication: Bool

    /// Always `.removable`; see the type's doc comment for why the other
    /// case is unreachable here.
    public var removability: Removability { .removable }

    /// A retained item is displayed and never deleted. This reads
    /// `retainedFor` rather than storing a separate flag so the two can
    /// never disagree — a row that names who retains it but reports itself
    /// deletable is the exact defect the retain-until-last rule exists to
    /// prevent.
    public var isDeletable: Bool { retainedFor.isEmpty }

    public init(
        path: URL,
        sizeBytes: Int64,
        evidence: EvidenceClass,
        sources: [EvidenceSource],
        retainedFor: Set<String>,
        claimCaveat: ClaimPopulation?,
        displayName: String,
        requiresAuthentication: Bool = false
    ) {
        self.requiresAuthentication = requiresAuthentication
        self.path = path
        self.sizeBytes = sizeBytes
        self.evidence = evidence
        self.sources = sources
        self.retainedFor = retainedFor
        self.claimCaveat = claimCaveat
        self.displayName = displayName
    }
}

/// A path this feature counted as belonging to the app but will not offer
/// for removal, because it falls outside the allowlisted roots.
///
/// Receipt manifests routinely name `/Applications` and `/Library` paths —
/// that is what a pkg install *is*. Dropping them silently would make the
/// app's reported footprint smaller than the truth, which is the one thing
/// this project's positioning does not permit. Disclosing them by count and
/// path, without a size, is the honest middle: the user learns the app owns
/// more than what is offered, and the assembler never walks a tree it has no
/// intention of removing.
public struct DisclosedPath: Sendable, Equatable {
    public let path: String
    public let source: EvidenceSource

    public init(path: String, source: EvidenceSource) {
        self.path = path
        self.source = source
    }
}

/// Why an entire footprint was refused, if it was.
///
/// Whole-assembly refusals, not per-item ones. A partial footprint of an app
/// that must not be touched is worse than no footprint: it invites removing
/// the half that got through.
public enum FootprintRefusal: Sendable, Equatable {

    /// The app is running right now. Its containers and preferences are open
    /// state a live process will rewrite, and the process existing is direct
    /// evidence the app is not gone.
    case appIsRunning

    /// Apple's own namespace, in any of the three spellings found on disk.
    /// Refused even when a caller names one directly — see `isAppleOwned`.
    case appleOwned
}

/// One app's assembled footprint.
///
/// Four disjoint outputs, deliberately not one list with flags: `items` is
/// what may be removed, `retained` is what is real but somebody else still
/// claims, `disclosedOutsideAllowlist` is what exists outside the roots this
/// engine may touch, and `refusedByPathGuard` is what sat inside those roots
/// and the safety backstop refused anyway. A caller that wants the honest
/// total has to look at all four; a caller that wants the safe total reads
/// `reclaimableBytes` and cannot accidentally include the other three.
public struct AppFootprint: Sendable {
    public let identity: BundleIdentity
    public let items: [FootprintItem]
    public let retained: [FootprintItem]
    public let disclosedOutsideAllowlist: [DisclosedPath]

    /// Paths that were attributed to the app, sat inside an allowlisted
    /// root, and were then refused by `PathGuard` anyway — a symlink, a
    /// root-owned entry, something too shallow.
    ///
    /// Without this field they vanish from every output list with nothing
    /// saying so. Undisclosed anything is what
    /// this product refuses, because the whole positioning is honesty about
    /// the number and a number the user cannot check is worth nothing.
    ///
    /// Not a correction term for any total. `PathGuard` runs before
    /// `collapseNested` (see that function's ordering note), so a refused path
    /// whose ancestor survived already has its bytes inside that ancestor's
    /// recursive measurement — disclosed *and* counted. Only a refused path
    /// with no surviving ancestor is absent from every figure, and this list
    /// cannot distinguish the two: it is the paths the safety backstop refused,
    /// nothing more.
    ///
    /// Disclosed by path and count, without a size, for the same reason
    /// `disclosedOutsideAllowlist` is — this engine does not walk trees it
    /// has no intention of removing.
    public let refusedByPathGuard: [DisclosedPath]

    public let refusal: FootprintRefusal?

    /// Sums `items` only — **never** `retained`.
    ///
    /// This is the retain-until-last rule expressed as arithmetic, and it is
    /// the number the whole feature's honesty claim rests on. A shared
    /// container's bytes belong to whoever removes the last claimant, not to
    /// whoever happens to be removed first; adding `retained` here would
    /// promise the user space that another installed app is still using.
    /// Pinned by `reclaimableBytesExcludeRetainedSharedItems`.
    public var reclaimableBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    public init(
        identity: BundleIdentity,
        items: [FootprintItem],
        retained: [FootprintItem],
        disclosedOutsideAllowlist: [DisclosedPath],
        refusedByPathGuard: [DisclosedPath] = [],
        refusal: FootprintRefusal?
    ) {
        self.identity = identity
        self.items = items
        self.retained = retained
        self.disclosedOutsideAllowlist = disclosedOutsideAllowlist
        self.refusedByPathGuard = refusedByPathGuard
        self.refusal = refusal
    }
}
