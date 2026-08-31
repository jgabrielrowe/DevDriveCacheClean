import Foundation

/// Rows the app lists largest-first. The tie-break is not cosmetic: without it,
/// equal-sized rows reorder between runs and the list reads as though the disk
/// changed when nothing did.
///
/// One comparator rather than a copy per call site, because six copies of the
/// same two-line closure is how the two halves of this app drift apart.
public protocol SizeRanked {
    var sizeBytes: Int64 { get }
    var path: URL { get }
}

extension FoundFile: SizeRanked {}
extension ScanResult: SizeRanked {}

extension Array where Element: SizeRanked {
    /// Size descending, path ascending. `sorted` is not guaranteed stable, so
    /// the tie-break must be explicit even where the input arrives ordered.
    public func inDisplayOrder() -> [Element] {
        sorted {
            $0.sizeBytes == $1.sizeBytes
                ? $0.path.path(percentEncoded: false) < $1.path.path(percentEncoded: false)
                : $0.sizeBytes > $1.sizeBytes
        }
    }
}
