import SwiftUI

/// Secondary text needs a different colour in each appearance, which is the
/// one thing a single `.tertiary` could not express.
///
/// Measured against the window background: `.tertiary` is 1.88:1 in light and
/// 2.26:1 in dark. The same token, and the light one is barely half the
/// contrast — which is why this read as fine for years to anyone in dark
/// appearance and was reported as unreadable by the first person to open it in
/// light. `.secondary` is not the fix either; it reaches only 3.95:1 in light.
///
/// So each appearance is pinned to its own value, chosen to land on the same
/// contrast ratio rather than the same alpha.
private struct SecondaryInk: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    /// Different alphas, near-identical contrast: 0.65 measures 4.77:1 in
    /// light and 0.55 measures 4.63:1 in dark. The numbers differ because the
    /// backgrounds do, and matching the *ratio* rather than the value is what
    /// makes the two appearances read the same. Both clear AA's 4.5:1, which
    /// `.tertiary` never did in either -- 1.88:1 light, 2.26:1 dark.
    func body(content: Content) -> some View {
        content.foregroundStyle(Color.primary.opacity(scheme == .dark ? 0.55 : 0.65))
    }
}

/// A sidebar heading, set in both appearances rather than deferring to
/// SwiftUI's own in dark.
///
/// 0.75 measures 6.58:1 in light and 7.42:1 in dark, so a heading sits above
/// the row subtitle's ~4.7:1 in both. It is read at a glance rather than
/// scanned, and the default dark heading colour was dimmer than the rows it
/// heads.
private struct HeadingInk: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(Color.primary.opacity(0.75))
    }
}

extension View {

    /// The small explanatory line beneath a row's title: the category under a
    /// path, the evidence under an app name, the retained count under a
    /// sidebar entry.
    ///
    /// The size is `.subheadline` because on macOS `.footnote`, `.caption` and
    /// `.caption2` are all 10pt. Moving between those three changes the code
    /// and not the pixels; `.subheadline` at 11pt is the first style that is
    /// genuinely larger, and it stays under the 13pt title it sits beneath.
    /// Size is deliberately not conditional — only the colour is.
    func rowSubtitle() -> some View {
        font(.subheadline).modifier(SecondaryInk())
    }

    /// The three top-level rows: Caches, Files, Uninstall. The sidebar's
    /// primary navigation, so they sit above the category rows rather than
    /// level with them.
    ///
    /// `.title3`, 15pt, rather than the 14 that would sit exactly one step
    /// above the 13pt rows. macOS has no semantic style at 14, and reaching it
    /// means `.system(size:)`, which is a fixed size: those rows would then be
    /// the only strings in the app that ignore the system text-size setting.
    /// A point of size is not worth being the exception.
    func sidebarModeTitle() -> some View {
        font(.title3)
    }

    /// A sidebar group heading, which has to be bigger than the rows it heads.
    ///
    /// `.headline` is 13pt, matching the `.body` of the category rows beneath
    /// it, so the separation comes from weight rather than size. SwiftUI's own
    /// sidebar header and `.callout` are both 12pt -- smaller than the list
    /// they head -- and `.title3` at 15pt overshot the mode rows above.
    ///
    /// Semibold as well as larger: it names the group rather than qualifying a
    /// row, which is the opposite job to the subtitle above.
    ///
    /// The size applies in both appearances; the colour is overridden only in
    /// light, where the default heading is too pale against a white sidebar.
    /// Dark keeps SwiftUI's own heading colour, which reads correctly there
    /// and is not `.tertiary` — imposing the row-subtitle ink here would have
    /// made the heading lighter in dark while making it darker in light.
    func sidebarSectionHeader() -> some View {
        font(.headline.weight(.bold)).modifier(HeadingInk())
    }
}
