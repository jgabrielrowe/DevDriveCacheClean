import Foundation

/// Why a result may or may not be selected for deletion.
///
/// A verdict rather than a boolean, because the UI needs to know *which* gate
/// it hit: which sheet to raise, which glyph to draw, which badge to show.
public enum Selectability: Equatable, Sendable {
    case selectable
    /// Tier 2. The whole category must be acknowledged once per scan.
    case needsCategoryAcknowledgement(CleanCategory)
    /// Tier 3. This one item must be opted into by hand.
    case needsItemOptIn
    /// The app cannot remove this path at all. No approval changes it.
    case lockedRequiresPrivileges
}

/// What the user has approved during the current scan.
///
/// Deliberately not persisted. Approval widens what the bulk tier toggles can
/// reach, and a grant that outlives the sitting it was made in is a grant
/// nobody is looking at. `AppViewModel.startScan()` clears it.
public struct ApprovalState: Equatable, Sendable {
    public private(set) var acknowledgedCategories: Set<CleanCategory>
    public private(set) var optedInItems: Set<UUID>

    public init() {
        self.acknowledgedCategories = []
        self.optedInItems = []
    }

    public mutating func acknowledge(_ category: CleanCategory) {
        acknowledgedCategories.insert(category)
    }

    public mutating func optIn(_ id: UUID) {
        optedInItems.insert(id)
    }

    public mutating func clear() {
        acknowledgedCategories = []
        optedInItems = []
    }
}

/// Which results the user may select for deletion, and why not when they may not.
public enum SelectionPolicy {

    /// First matching rule wins. `isDeletable` is checked before tier because a
    /// row the app cannot remove is never selectable no matter what is approved.
    public static func selectability(
        of result: ScanResult, given approval: ApprovalState
    ) -> Selectability {
        guard result.isDeletable else { return .lockedRequiresPrivileges }

        switch result.tier {
        case .safe:
            return .selectable
        case .costly:
            return approval.acknowledgedCategories.contains(result.category)
                ? .selectable
                : .needsCategoryAcknowledgement(result.category)
        case .destructive:
            return approval.optedInItems.contains(result.id)
                ? .selectable
                : .needsItemOptIn
        }
    }

    /// The ids a bulk action may add for `tier`.
    ///
    /// `.destructive` returns empty unconditionally. An opted-in tier 3 row is
    /// `.selectable`, so filtering on selectability alone would let a Select-All
    /// style action sweep it up — the one thing that must never happen. Tier 3
    /// is reachable one item at a time, by hand, or not at all.
    public static func bulkSelectableIDs(
        from results: [ScanResult], given approval: ApprovalState, tier: RemovalTier
    ) -> Set<UUID> {
        guard tier != .destructive else { return [] }
        return Set(
            results.lazy
                .filter { $0.tier == tier && selectability(of: $0, given: approval) == .selectable }
                .map(\.id)
        )
    }
}
