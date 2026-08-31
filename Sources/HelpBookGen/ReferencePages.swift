import Foundation
import DDCCCore

/// One generated page of the help book.
public struct ReferencePage: Sendable {
    public let filename: String
    /// Becomes the page's `AppleTitle`, so it must be unique within the book.
    public let title: String
    public let markdown: String
}

/// The reference half of the help book, generated from the `HelpText`
/// catalogue.
///
/// Generated rather than written because these 38 entries already exist as
/// tooltips. Writing them twice is how shipped documentation drifts from the
/// interface it documents, and the catalogue's two forms exist precisely so it
/// cannot happen here.
public enum ReferencePages {

    public static var all: [ReferencePage] { [tiers, removability, categories, files] }

    private static func entry(anchor: String, heading: String, body: String) -> String {
        """
        <a name="\(anchor)"></a>

        ### \(heading)

        \(body)
        """
    }

    static var tiers: ReferencePage {
        let body = RemovalTier.allCases.map {
            entry(anchor: $0.helpAnchor, heading: $0.label, body: HelpText.for($0).long)
        }.joined(separator: "\n\n")
        return ReferencePage(
            filename: "reference-tiers.md",
            title: "The three tiers",
            markdown: """
            # The three tiers

            Tiers describe the risk of removing an item. They also control how \
            DDCC lets you select it.

            \(body)
            """
        )
    }

    /// Exhaustive on purpose, with no `default:` branch, for the same reason
    /// as `heading(for: FinderHelpTopic)` below: a new `Removability` case
    /// must not reach the help book unlabelled.
    private static func heading(for removability: Removability) -> String {
        switch removability {
        case .removable: return "Removable"
        case .requiresPrivileges: return "Shown but never removed"
        }
    }

    /// Every fixed path in the scan profiles that is scanned but never offered
    /// for deletion. Read from the profiles rather than listed here, so the page
    /// cannot claim a path the app does not actually refuse.
    static var neverRemovedPaths: [String] {
        ScanProfile.all
            .flatMap(\.patterns)
            .filter { $0.removability == .requiresPrivileges }
            .compactMap { pattern in
                if case .absolutePath(let path) = pattern.kind { return path }
                return nil
            }
            .sorted()
    }

    static var removability: ReferencePage {
        let body = Removability.allCases.map { removability -> String in
            var text = HelpText.for(removability).long
            // The closed set is the answer to "can DDCC delete this?", so it is
            // listed in full rather than sampled.
            if removability == .requiresPrivileges, !neverRemovedPaths.isEmpty {
                text += "\n\nThe paths this applies to:\n\n"
                    + neverRemovedPaths.map { "- `\($0)`" }.joined(separator: "\n")
            }
            return entry(anchor: removability.helpAnchor,
                         heading: heading(for: removability),
                         body: text)
        }.joined(separator: "\n\n")
        return ReferencePage(
            filename: "reference-removability.md",
            title: "What DDCC can and cannot remove",
            markdown: """
            # What DDCC can and cannot remove

            Some paths are visible because they use disk space, but DDCC cannot \
            remove them with your current permissions.

            \(body)
            """
        )
    }

    static var categories: ReferencePage {
        let body = CleanCategory.allCases.map {
            entry(anchor: $0.helpAnchor, heading: $0.rawValue, body: HelpText.for($0).long)
        }.joined(separator: "\n\n")
        return ReferencePage(
            filename: "reference-categories.md",
            title: "Categories",
            markdown: """
            # Categories

            What each Caches category contains, and what usually recreates it.

            \(body)
            """
        )
    }

    /// Exhaustive on purpose, with no `default:` branch: a new
    /// `FinderHelpTopic` case must not reach the help book with a raw
    /// camelCase heading, so it must not compile until someone decides its
    /// heading — the same guarantee `HelpAnchor.swift` gives anchors.
    private static func heading(for topic: FinderHelpTopic) -> String {
        switch topic {
        case .mode: return "The Files view"
        case .find: return "Find"
        case .stop: return "Stop"
        case .root: return "Search folder"
        case .sizeThreshold: return "Minimum size"
        case .ageThreshold: return "Unmodified for"
        case .rowCheckbox: return "Selecting a row"
        case .deselectAll: return "Deselect all"
        case .trash: return "Move to Trash"
        case .reveal: return "Show in Finder"
        case .partialSize: return "Sizes marked with a plus"
        }
    }

    static var files: ReferencePage {
        let body = FinderHelpTopic.allCases.map {
            entry(anchor: $0.helpAnchor, heading: heading(for: $0), body: $0.helpText.long)
        }.joined(separator: "\n\n")
        return ReferencePage(
            filename: "reference-files.md",
            title: "The Files view controls",
            markdown: """
            # The Files view controls

            The Files view searches for large, long-unmodified files outside the \
            cache categories. It only moves selected items to the Trash.

            \(body)
            """
        )
    }
}

extension ReferencePages {
    /// Every anchor the catalogue declares, for `make-app.sh` to check against
    /// the built HTML.
    public static var allAnchors: [String] {
        RemovalTier.allCases.map(\.helpAnchor)
            + Removability.allCases.map(\.helpAnchor)
            + CleanCategory.allCases.map(\.helpAnchor)
            + FinderHelpTopic.allCases.map(\.helpAnchor)
    }
}
