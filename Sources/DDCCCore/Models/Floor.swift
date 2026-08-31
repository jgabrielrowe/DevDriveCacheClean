import Foundation

/// The "+" that marks a number as a floor rather than a total.
///
/// Appended by both models' `formattedSize`, the Files sidebar total, the
/// category totals and the swept-rows count. One home because the marker is a
/// promise to the reader — explained once in `ReadoutHelpTopic.incomplete` —
/// and because scattered ternaries invited opposite polarities.
public enum Floor {

    /// `base` unchanged when the figure is exact, with a trailing "+" when not.
    /// Takes the exact side because that is what `ScanCompleteness` publishes.
    public static func marked(_ base: String, exact: Bool) -> String {
        exact ? base : base + "+"
    }

    /// Preferred where a `ScanCompleteness` is at hand: it cannot be passed the
    /// wrong way round.
    public static func marked(_ base: String, _ completeness: ScanCompleteness) -> String {
        marked(base, exact: completeness.isExact)
    }
}
