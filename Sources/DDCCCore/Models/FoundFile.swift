import Foundation

/// One row of the Files view: a file, or a bundle reported whole.
///
/// Deliberately not a `ScanResult`. A `ScanResult` carries a category and a
/// tier, both of which mean "an audited pattern vouched for this path and
/// knows what losing it costs". Nothing vouches for a found file, so those
/// fields could only hold a guess — and a guess in the tier enum stops the
/// tier model describing blast radius everywhere else.
public struct FoundFile: Identifiable, Sendable, Equatable, Deletable {
    public let id = UUID()
    public let path: URL
    public let sizeBytes: Int64
    public let lastModified: Date?
    /// True when this is a package (`.app`, `.photoslibrary`, `.sparsebundle`)
    /// reported as one object rather than traversed into.
    public let isBundle: Bool
    /// True when `sizeBytes` is a floor because some descendants were
    /// unreadable. Defaulted so existing construction sites are unaffected;
    /// only a bundle measured through `SizeCalculator` can set this.
    public let partialRead: Bool

    public init(
        path: URL, sizeBytes: Int64, lastModified: Date?, isBundle: Bool,
        partialRead: Bool = false
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.isBundle = isBundle
        self.partialRead = partialRead
    }

    public var displayName: String { path.lastPathComponent }

    public var removability: Removability { .removable }

    /// Unconditionally true. This is a contract on whoever constructs a
    /// `FoundFile`: apply `PathGuard` during traversal and drop a refused
    /// path rather than emitting it, so every value reaching a caller is one
    /// the guard allowed. There is no locked-informational equivalent in this
    /// view — the finder either shows a row you can act on, or does not show
    /// it.
    public var isDeletable: Bool { true }

    public var relativePath: String { PathDisplay.tildeAbbreviated(path) }

    public var formattedSize: String {
        let base = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return Floor.marked(base, exact: !partialRead)
    }

    /// Never says "unused". A reference PDF opened weekly is genuinely
    /// unmodified, and implying it is abandoned would be the same category of
    /// dishonesty as understating a size.
    public var unmodifiedDescription: String {
        guard let lastModified else { return "Modified date unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Unmodified \(formatter.localizedString(for: lastModified, relativeTo: Date()))"
    }

    /// By value, not by `id`. `id` is a fresh `UUID()` per instance and exists
    /// only for `Identifiable`; including it — which the synthesised `==` would
    /// do — means two rows describing the same file compare unequal, so this
    /// operator has to stay written out.
    public static func == (lhs: FoundFile, rhs: FoundFile) -> Bool {
        lhs.path == rhs.path
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.lastModified == rhs.lastModified
            && lhs.isBundle == rhs.isBundle
            && lhs.partialRead == rhs.partialRead
    }
}
