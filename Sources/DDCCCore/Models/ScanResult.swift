import Foundation

public struct ScanResult: Identifiable, Sendable {
    public let id = UUID()
    public let path: URL
    public let category: CleanCategory
    public let tier: RemovalTier
    public let removability: Removability
    public var sizeBytes: Int64
    public let lastModified: Date?
    public let displayName: String
    /// True when `sizeBytes` is a floor because some descendants were unreadable.
    public let partialRead: Bool
    /// The directories inside this one that refused enumeration, each named.
    /// Carried rather than counted so `RefusalSet` can collapse them against
    /// refusals another engine found for the same directory.
    ///
    /// A carrier, not a queryable API. It exists so a sized candidate's
    /// refusals survive `Measurer.outcome(...)` and reach the fold in
    /// `Measurer.measure(...)` — the only consumer in the codebase, and the
    /// only one there should be. Anything wanting a refusal count wants
    /// `MeasureOutcome.refusals` or `ScanCompleteness.unreadableDirectories`,
    /// both of which are deduplicated across engines; summing this per row is
    /// how one sealed directory got counted twice in the first place.
    public let unreadablePaths: Set<String>
    /// Bytes inside this item that removing it would not free, because a hard
    /// link somewhere outside keeps the content alive.
    ///
    /// Separate from `sizeBytes` on purpose: `sizeBytes` is what the user gets
    /// back, and this is what the folder appears to hold but does not own. A
    /// pnpm `node_modules` is the case that matters — most of its apparent size
    /// lives in a store that outlives the delete. Adding the two together would
    /// reconstruct exactly the inflated figure this separation exists to stop.
    public let sharedBytesWithheld: Int64
    /// False for locked informational rows. Selection UI must respect this.
    public let isDeletable: Bool

    public init(
        path: URL,
        category: CleanCategory,
        tier: RemovalTier,
        removability: Removability,
        sizeBytes: Int64,
        lastModified: Date?,
        displayName: String,
        partialRead: Bool,
        unreadablePaths: Set<String>,
        sharedBytesWithheld: Int64 = 0,
        isDeletable: Bool
    ) {
        self.path = path
        self.category = category
        self.tier = tier
        self.removability = removability
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.displayName = displayName
        self.partialRead = partialRead
        self.sharedBytesWithheld = sharedBytesWithheld
        self.unreadablePaths = unreadablePaths
        self.isDeletable = isDeletable
    }

    public var formattedSize: String {
        let base = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return Floor.marked(base, exact: !partialRead)
    }

    /// True when part of this item's apparent size is content some other name
    /// keeps alive, so removing this item would not release it.
    public var sharesContentElsewhere: Bool { sharedBytesWithheld > 0 }

    /// The withheld figure, formatted like every other size in the app.
    ///
    /// Never suffixed with `+`. The plus means "at least this much, because
    /// something could not be read"; this number was read exactly and simply
    /// belongs to someone else too.
    public var formattedSharedBytesWithheld: String {
        ByteCountFormatter.string(fromByteCount: sharedBytesWithheld, countStyle: .file)
    }

    public var relativePath: String { PathDisplay.tildeAbbreviated(path) }

    public var age: String {
        guard let date = lastModified else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
