// Sources/DDCCCore/Models/ReadoutHelpTopic.swift
import Foundation

/// Copy for the parts of the interface that *report* rather than act.
///
/// `FinderHelpTopic` covers the Files view's controls and `HelpText.for(_:)`
/// covers categories and tiers, but the completeness readout — the tray icon
/// and the caveat line under it — had no copy at all. Those are the app's
/// own vocabulary for how much of an answer it is giving, and nothing on
/// screen defined either: a green check and an orange exclamation mark
/// differ by a colour, and "3 folders could not be read • 2 sizes partial"
/// names three separate mechanisms in eleven words.
///
/// Same reason `UninstallWording.reclaimableHelp` exists. A figure a user
/// forms an expectation from should be able to say what it means.
public enum ReadoutHelpTopic: String, CaseIterable, Sendable {

    /// The completeness marker when the run read everything it targeted.
    case exact

    /// The completeness marker when the run finished but something was
    /// unreadable.
    case incomplete

    /// The completeness marker for a run the user stopped.
    case stopped

    /// The caveat line itself — the clauses under the marker.
    case caveat

    /// A row's glyph in the Files list, for a plain file.
    case foundFile

    /// A row's glyph in the Files list, for a bundle.
    case foundBundle

    public var helpText: HelpText {
        switch self {
        case .exact:
            return HelpText(
                short: "This run read everything it set out to read.",
                long: "Every path this run targeted was readable and every size was measured, "
                    + "so the total is a measurement rather than a floor. It is still only a "
                    + "total for what this run looked at — a different scan root or different "
                    + "filters would look at different things."
            )
        case .incomplete:
            return HelpText(
                short: "This run finished, but something could not be read — the total is a floor.",
                long: "The run completed, and then found it could not read part of what it "
                    + "targeted: a folder macOS refused, or a size it could only partly "
                    + "measure. What is on screen is real; there is more that could not be "
                    + "counted, so treat the total as a minimum."
            )
        case .stopped:
            return HelpText(
                short: "Stopped before it finished, so the total is a floor whatever else it says.",
                long: "Whatever the run had already found stays on screen, but it never reached "
                    + "the end, so the total is a floor for that reason alone — independently "
                    + "of anything it could or could not read. Run it again for a complete "
                    + "answer."
            )
        case .caveat:
            return HelpText(
                short: "Each part names something this run could not fully read.",
                long: "\"Folders could not be read\" counts directories macOS refused outright. "
                    + "\"Sizes partial\" counts items measured only in part, whose size is a "
                    + "floor. \"Items not measured\" counts what the run never reached at all. "
                    + "Each is a different reason the total understates what is on disk."
            )
        case .foundFile:
            return HelpText(
                short: "A single file.",
                long: "One file, whose size is its own. Files from this view can only ever be "
                    + "moved to the Trash."
            )
        case .foundBundle:
            return HelpText(
                short: "A bundle — one item in Finder, a folder of many files underneath.",
                long: "macOS presents a bundle as a single object, so its size is the total of "
                    + "everything inside it rather than of one file. Bundles from this view can "
                    + "only ever be moved to the Trash."
            )
        }
    }
}
