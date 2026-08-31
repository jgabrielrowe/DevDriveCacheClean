// Sources/DDCCCore/Models/CategoryGroup.swift
import Foundation

/// The two groups the sidebar splits `CleanCategory` into.
///
/// Names the two sides of `CleanCategory.isDeveloper`, which the sidebar would
/// otherwise spell as literals. Both groups hold caches and only caches — the
/// Files and Uninstall views sit in the same sidebar and hold neither — and a
/// literal heading leaves the reader to infer that.
public enum CategoryGroup: String, CaseIterable, Sendable {
    case developer
    case system

    /// Which group a category belongs to. Derived from `isDeveloper` rather
    /// than restated, so a category cannot be in one group here and the
    /// other there.
    public static func of(_ category: CleanCategory) -> CategoryGroup {
        category.isDeveloper ? .developer : .system
    }

    public var title: String {
        switch self {
        case .developer: return "Developer Caches"
        case .system: return "System & App Caches"
        }
    }

    public var helpText: HelpText {
        switch self {
        case .developer:
            return HelpText(
                short: "Caches and build output left by developer tools.",
                long: "Package installs, build artifacts and tool caches created by developer "
                    + "tooling. Most of it is rebuilt from files already on your Mac, which is "
                    + "why so much of this group sits in the safe tier."
            )
        case .system:
            return HelpText(
                short: "Caches left by macOS and by the apps you have installed.",
                long: "Cache and support data written by macOS itself and by installed "
                    + "applications. Removing it is generally safe, but some of it is "
                    + "re-downloaded rather than rebuilt, so parts of this group cost "
                    + "bandwidth to recreate."
            )
        }
    }
}
