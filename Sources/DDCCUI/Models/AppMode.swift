import Foundation

/// Which view the window is showing.
///
/// A mode rather than another `CleanCategory`: Files rows are unaudited and
/// carry no tier, so listing them beside audited rows under the same
/// vocabulary would make the tier column meaningless for both.
enum AppMode: String, CaseIterable, Identifiable {
    case caches
    case files
    case uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: return "Caches"
        case .files: return "Files"
        case .uninstall: return "Uninstall"
        }
    }

    var icon: String {
        switch self {
        case .caches: return "shippingbox"
        case .files: return "doc.text.magnifyingglass"
        case .uninstall: return "trash.square"
        }
    }
}

/// Symbols for the actions the three views share.
///
/// `startSweep` exists because all three views were reaching for their own
/// glyph and two of them landed on `magnifyingglass` — the same symbol macOS
/// draws inside the search field sitting a few points away. A button and a
/// filter field showing the same icon while doing unrelated things is what
/// reads as jarring on first use, and the fix is one
/// symbol across all three views rather than three distinct ones, so that
/// moving between views does not mean relearning which control starts the
/// work.
///
/// `binoculars` over a radar or reticle glyph: what these three do is go and
/// look, and none of them emits anything or targets a point.
enum ActionGlyph {
    /// Caches' Scan, Files' Find, Uninstall's Sweep. One symbol, three verbs
    /// — the verbs differ because what each view returns differs, but the
    /// act of starting it does not.
    static let startSweep = "binoculars"

    /// Stopping any of the three. Already shared in practice; named here so
    /// it stays that way.
    static let stop = "stop.fill"
}
