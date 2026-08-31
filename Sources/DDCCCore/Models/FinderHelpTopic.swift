import Foundation

/// Every help entry belonging to the Files view.
///
/// This enum is the single source of truth for these entries: a new one has
/// nowhere to live except a new case, so `allCases` can never miss one. That
/// replaces an earlier design where the copy lived in separate `HelpText`
/// statics and a hand-maintained array tried to list them — a second list
/// that could silently fall out of step with the first.
public enum FinderHelpTopic: String, CaseIterable, Sendable {
    case mode
    case find
    case stop
    case root
    case sizeThreshold
    case ageThreshold
    case rowCheckbox
    case deselectAll
    case trash
    case reveal
    case partialSize

    public var helpText: HelpText {
        switch self {
        case .mode:
            return HelpText(
                short: "Find large files outside the cache categories.",
                long: "The Files view searches for large, long-unmodified files and bundles "
                    + "outside DDCC's cache categories. Review each result yourself; files "
                    + "from this view can only be moved to the Trash."
            )
        case .find:
            return HelpText(
                short: "Search the chosen folder with the current size and age filters.",
                long: "Searches the selected folder for files and bundles that pass both filters. "
                    + "DDCC skips ~/Library and paths already covered by the Caches view."
            )
        case .stop:
            return HelpText(
                short: "Stop the search. No partial results are kept.",
                long: "Stops the current Files search and clears its in-progress results. Run "
                    + "Find again when you want a complete list."
            )
        case .root:
            return HelpText(
                short: "Choose which folder to search.",
                long: "The default is your home directory. If you choose a folder inside "
                    + "~/Library, the Files view may find nothing because library paths are "
                    + "handled by the Caches view."
            )
        case .sizeThreshold:
            return HelpText(
                short: "Only report files at least this large.",
                long: "A file must meet both the size and age filters to appear. Choose Any "
                    + "size when you want to filter only by age."
            )
        case .ageThreshold:
            return HelpText(
                short: "Only report files unmodified for at least this long.",
                long: "Uses the modification date, not the last time you opened the file. A "
                    + "document you read often but never edit can still appear as unmodified."
            )
        case .rowCheckbox:
            return HelpText(
                short: "Select this file for the Trash.",
                long: "Files are never selected automatically, and there is no select-all in "
                    + "this view. Choose each file or bundle by hand."
            )
        case .deselectAll:
            return HelpText(
                short: "Clear the whole selection.",
                long: "Clears every selected row, including rows a filter is currently hiding."
            )
        case .trash:
            return HelpText(
                short: "Move the selected files to the Trash.",
                long: "Moves the selected files and bundles to the Trash, where they can be "
                    + "put back. The Files view does not offer permanent deletion."
            )
        case .reveal:
            return HelpText(
                short: "Show this file in the Finder.",
                long: "Opens a Finder window with this file selected so you can inspect it "
                    + "before moving it."
            )
        case .partialSize:
            return HelpText(
                short: "A plus means DDCC could not read everything inside this item.",
                long: "A size with a trailing plus is a lower bound. DDCC measured what it "
                    + "could read, but the real size may be larger."
            )
        }
    }
}
