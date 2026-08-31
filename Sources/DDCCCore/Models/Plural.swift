import Foundation

/// A count and the noun it counts, with only the noun inflecting.
///
/// One home for the five readouts that state a count: the sidebar's category
/// subtitle, both approval sheets, the trash sheet's summary and the
/// swept-rows readout.
public enum Plural {

    /// `of(1, "item")` is "1 item"; `of(3, "item")` is "3 items". Pass
    /// `plural` for a noun that does not take a bare "s".
    public static func of(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }
}
