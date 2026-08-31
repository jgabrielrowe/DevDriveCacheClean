import Foundation

/// Every reason a scan's total is less than the whole truth, in one value.
///
/// Without this, a run that could not read half the disk renders as "0 items
/// - Zero KB", indistinguishable from a clean one.
///
/// A struct rather than an enum, because a run can be stopped early *and* have
/// hit unreadable directories *and* contain floored sizes at the same time.
/// One-of-N would force a lie.
public struct ScanCompleteness: Sendable, Equatable {
    /// Directories whose listing failed. The reader may have returned a prefix,
    /// so everything below them is missing from the total.
    public let unreadableDirectories: Int
    /// Sizes that are floors rather than measurements, per `FoundFile.partialRead`.
    public let flooredItems: Int
    /// Candidates discovered but never sized, because cancellation reached them
    /// first. They are absent from the results entirely, so without this count a
    /// stopped scan reads as a smaller complete one.
    public let unmeasuredItems: Int

    public init(unreadableDirectories: Int, flooredItems: Int, unmeasuredItems: Int) {
        self.unreadableDirectories = unreadableDirectories
        self.flooredItems = flooredItems
        self.unmeasuredItems = unmeasuredItems
    }

    /// A run that knows everything it reported. Deliberately not a default
    /// argument anywhere: every construction site states its completeness, so a
    /// new status surface cannot silently inherit "exact" it did not earn.
    public static let exact = ScanCompleteness(
        unreadableDirectories: 0, flooredItems: 0, unmeasuredItems: 0)

    public var isExact: Bool {
        unreadableDirectories == 0 && flooredItems == 0 && unmeasuredItems == 0
    }

    /// One line naming every reason this total falls short, or nil when it does
    /// not. Lives here rather than in a view so both status trays and anything
    /// added later say the same thing, and so it can be tested without a view.
    public var caveat: String? {
        guard !isExact else { return nil }
        var parts: [String] = []
        if unreadableDirectories > 0 {
            parts.append(
                "\(unreadableDirectories) folder\(unreadableDirectories == 1 ? "" : "s") could not be read")
        }
        if flooredItems > 0 {
            parts.append("\(flooredItems) size\(flooredItems == 1 ? "" : "s") partial")
        }
        if unmeasuredItems > 0 {
            parts.append("\(unmeasuredItems) item\(unmeasuredItems == 1 ? "" : "s") not measured")
        }
        return parts.joined(separator: " \u{2022} ")
    }
}
