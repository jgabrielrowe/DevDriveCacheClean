/// The order topics appear in the book's navigation.
///
/// This is editorial information, not derivable information, which is why it
/// is stated here rather than computed. `BundleWriter` walks the two Markdown
/// directories alphabetically, and the book does not read alphabetically:
/// "What DDCC does" belongs before "Your first scan" for reasons no sort can
/// know. The defect this project keeps deleting is a *second* copy of a
/// derivable fact; an ordering has no first copy to derive from.
///
/// What keeps it honest is `NavigationTests`, which reads `Help/pages/` and
/// `Help/generated/` from disk and fails if a page here is missing from disk
/// or a page on disk is missing from here. Adding a page without placing it
/// forces a decision instead of silently dropping it out of the nav.
public enum Navigation {
    /// The book's front page. It heads the nav rather than sitting in a group.
    public static let home = "index"

    /// Authored narrative pages, in reading order. Live in `Help/pages/`.
    public static let topics: [String] = [
        "what-ddcc-does",
        "honest-number",
        "first-scan",
        "reading-results",
        "choosing-what-to-remove",
        "unlocking-tiers",
        "deleting-cache-results",
        "files-view",
        "uninstall-view",
        "trash-not-delete",
        "full-disk-access",
        "privacy",
    ]

    /// Generated reference pages, in reading order. Live in `Help/generated/`.
    public static let reference: [String] = [
        "reference-tiers",
        "reference-categories",
        "reference-removability",
        "reference-files",
    ]

    /// Every page in the book, in the order the nav presents them.
    public static var all: [String] { [home] + topics + reference }
}
