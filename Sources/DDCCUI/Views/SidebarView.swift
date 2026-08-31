import SwiftUI
import DDCCCore

/// The sidebar's selection type.
///
/// `List(selection:)` treats a nil selection as "nothing is selected", so a row
/// tagged `nil as CleanCategory?` can never become the selection and clicking it
/// does nothing. "All" needs to be a real value, not the absence of one.
private enum SidebarSelection: Hashable {
    case mode(AppMode)
    case all
    case category(CleanCategory)
}

struct SidebarView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(FinderViewModel.self) private var finderViewModel
    @Environment(UninstallViewModel.self) private var uninstallViewModel

    // Expanded by default: the sidebar is how the user discovers what was found,
    // and a collapsed section on launch would hide the results behind a click.
    @State private var developerExpanded = true
    @State private var systemExpanded = true

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                switch viewModel.mode {
                case .caches:
                    return viewModel.selectedCategory.map(SidebarSelection.category) ?? .all
                case .files:
                    return .mode(.files)
                case .uninstall:
                    return .mode(.uninstall)
                }
            },
            set: { newValue in
                switch newValue {
                case .mode(let mode):
                    viewModel.mode = mode
                case .category(let category):
                    viewModel.mode = .caches
                    viewModel.selectedCategory = category
                case .all, nil:
                    viewModel.mode = .caches
                    viewModel.selectedCategory = nil
                }
            }
        )
    }

    private var devCategories: [(category: CleanCategory, count: Int, totalSize: Int64, lockedSize: Int64)] {
        viewModel.categorySummary.filter { $0.category.isDeveloper }
    }

    private var systemCategories: [(category: CleanCategory, count: Int, totalSize: Int64, lockedSize: Int64)] {
        viewModel.categorySummary.filter { !$0.category.isDeveloper }
    }

    var body: some View {
        List(selection: selection) {
            // One unheaded group. Three rows that name themselves need no
            // fourth noun above them, and a header repeating its only row's
            // name says nothing. Ordered as the Actions menu orders them and
            // as the app launches, so the primary mode is not listed last.
            Section {
                Label {
                    HStack {
                        // Was the literal "All", which said nothing about what
                        // it held once the Files view existed alongside it.
                        // Taken from AppMode rather than restated, so this row
                        // and the window title cannot drift apart.
                        Text(AppMode.caches.title)
                        Spacer()
                        if !viewModel.results.isEmpty {
                            VStack(alignment: .trailing) {
                                Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSize, countStyle: .file))
                                    .font(.caption)
                                if viewModel.lockedSize > 0 {
                                    Text("\(ByteCountFormatter.string(fromByteCount: viewModel.lockedSize, countStyle: .file)) locked")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "tray.full")
                }
                .tag(SidebarSelection.all)
                .contentShape(Rectangle())
                .help("Every cache found by the last scan, across all categories.")

                Label {
                    ModeRowContent(
                        title: AppMode.files.title,
                        primary: finderViewModel.sidebarTotalText,
                        secondary: finderViewModel.sidebarUnreadableText)
                } icon: {
                    Image(systemName: AppMode.files.icon)
                }
                .tag(SidebarSelection.mode(AppMode.files))
                .contentShape(Rectangle())
                .help(FinderHelpTopic.mode.helpText.short)

                Label {
                    // Both figures labelled. An unlabelled number beside
                    // "Uninstall" reads as "what I get back", and the retained
                    // figure is the one most likely to be read as a bug, so it
                    // never sits silently inside the figure above it.
                    ModeRowContent(
                        title: AppMode.uninstall.title,
                        primary: uninstallViewModel.sidebarReclaimableText.map { "\($0) reclaimable" },
                        secondary: uninstallViewModel.sidebarRetainedText.map { "\($0) retained" })
                } icon: {
                    Image(systemName: AppMode.uninstall.icon)
                }
                .tag(SidebarSelection.mode(AppMode.uninstall))
                .contentShape(Rectangle())
                .help("What every installed app — and every app already gone — left behind.")
            }


            if !devCategories.isEmpty {
                Section(isExpanded: $developerExpanded) {
                    ForEach(devCategories, id: \.category) { item in
                        CategoryRow(item: item)
                            .tag(SidebarSelection.category(item.category))
                    }
                } header: {
                    SidebarSectionHeader(group: .developer, isExpanded: $developerExpanded)
                }
            }

            if !systemCategories.isEmpty {
                Section(isExpanded: $systemExpanded) {
                    ForEach(systemCategories, id: \.category) { item in
                        CategoryRow(item: item)
                            .tag(SidebarSelection.category(item.category))
                    }
                } header: {
                    SidebarSectionHeader(group: .system, isExpanded: $systemExpanded)
                }
            }
        }
        .navigationTitle("DevDriveCacheClean")
        // The expand animation, killed outright — measured, not guessed.
        //
        // Rows descended from the top of the sidebar column
        // instead of from under their header. A five-variant probe ruled out
        // everything this view does: the bottom status tray, the
        // `if !categories.isEmpty` wrappers, the computed selection binding,
        // and `NavigationSplitView` itself. It reproduces on a bare
        // `List { Section(isExpanded:) }`, so it is SwiftUI's own insertion
        // transition rather than anything here.
        //
        // Measured: it reproduces on a bare `List { Section(isExpanded:) }`
        // with a single section at the very top of the list, and suppressing
        // the transaction is what stops it.
        //
        // The mechanism is NOT established, and one appealing explanation is
        // ruled out. The first round's reports had the first section looking
        // fine while later ones did not, which fits "the rows always fly from
        // y=0, so the artifact is invisible when the header is already at the
        // top". Round two disproved it: a lone section at the top glitches
        // too. Why it looked clean in the first round is unexplained. Nothing
        // here rests on knowing — the fix is pinned by reproduction, not by
        // theory — but do not re-derive that theory from the first round's
        // symptom, because it has already been tested and failed.
        //
        // Two other fixes were tried on the same fixture and neither worked:
        // a `DisclosureGroup` in place of `Section(isExpanded:)`, and an
        // explicit `.transition(.opacity)` on the rows. `Section(isExpanded:)`
        // keeps its transition whatever it is handed, which leaves removing
        // the transaction as the only lever that reaches it.
        //
        // The cost is real and deliberate: this suppresses animation for the
        // whole sidebar, not just the two collapsible sections, because the
        // disclosure control starts the transaction outside them and a
        // `.transaction` scoped to a `Section` never sees it. Rows now appear
        // and disappear instantly. That is a plainer sidebar than before and
        // a correct one, which is the trade taken.
        .transaction { $0.animation = nil }
        .safeAreaInset(edge: .bottom) {
            ScanStatusBar()
        }
    }
}

/// The Files and Uninstall rows, shaped like the Caches "All" row above
/// them: a title, then whatever the last run reported, trailing.
///
/// Both figures arrive already formatted. That is deliberate and is what
/// keeps `EngineOverlapTests` meaningful — the sidebar is the one file
/// holding a Caches total and an Uninstall total at once, and a view with no
/// numbers in it has nothing to add together. See that test's own comment
/// for the 12.1 GB it exists to stop being reported as 23 GB.
struct ModeRowContent: View {
    let title: String
    let primary: String?
    let secondary: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let primary {
                VStack(alignment: .trailing) {
                    Text(primary)
                        .font(.caption)
                    if let secondary {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A collapsible section's header, with the whole header as its hit target
/// rather than the disclosure arrow alone.
///
/// The arrow is a small target for something whose meaning is the entire
/// header, and every other outline view on macOS — Finder's sidebar, Xcode's
/// navigator — toggles on the title too. `.contentShape` is what makes the
/// gap between the title and the arrow live; without it the tap only lands
/// on the glyphs of the word itself.
///
/// The toggle is wrapped in `withAnimation` rather than left to SwiftUI's
/// implicit animation, so the rows animate as one change driven from here.
struct SidebarSectionHeader: View {
    let group: CategoryGroup
    @Binding var isExpanded: Bool

    var body: some View {
        Text(group.title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // No `withAnimation`. The list suppresses animation for this
            // change anyway (see `SidebarView.body`), and wrapping it here
            // would state an intent the view immediately overrides — worse,
            // it would suggest the title and the arrow take different paths,
            // which they do not, confirmed by hand.
            .onTapGesture { isExpanded.toggle() }
            .help(group.helpText.short)
    }
}

struct CategoryRow: View {
    let item: (category: CleanCategory, count: Int, totalSize: Int64, lockedSize: Int64)

    var body: some View {
        Label {
            HStack {
                Text(item.category.rawValue)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(ByteCountFormatter.string(fromByteCount: item.totalSize, countStyle: .file))
                        .font(.caption)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: item.category.icon)
        }
        // The whole row is the hover target, not just the glyph and the
        // glyphs' text. A `Label` in a `List` row draws only where its
        // content is; the trailing figures sit in their own `VStack` and the
        // gap between is nothing at all, so a tooltip attached without this
        // appears over some of the row and not the rest — which reads as no
        // tooltip, since a user hovers the row, not the word.
        .contentShape(Rectangle())
        // The same string the help book prints for this category, not a second
        // description of it.
        .help(HelpText.for(item.category).short)
    }

    private var subtitle: String {
        let items = Plural.of(item.count, "item")
        guard item.lockedSize > 0 else { return items }
        let locked = ByteCountFormatter.string(fromByteCount: item.lockedSize, countStyle: .file)
        return "\(items) · \(locked) locked"
    }
}

struct ScanStatusBar: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(FinderViewModel.self) private var finderViewModel
    @Environment(UninstallViewModel.self) private var uninstallViewModel

    /// Which lifecycle this tray reports on. The sidebar is shared by all
    /// three modes, but each sweep is independent, so showing one mode's
    /// state while the user is looking at another would be reporting on the
    /// wrong thing entirely.
    private var isIdle: Bool {
        switch viewModel.mode {
        case .caches:
            if case .idle = viewModel.scanState { return true }
            return false
        case .files:
            if case .idle = finderViewModel.state { return true }
            return false
        case .uninstall:
            return !uninstallViewModel.isSweeping && uninstallViewModel.report == nil
        }
    }

    /// A footer tray, not floating text. As a bare `safeAreaInset` with no
    /// background the sidebar's rows scrolled underneath and showed through it,
    /// so the scan summary appeared to sit on top of unrelated content. The
    /// separator and material give it its own surface; when idle it collapses
    /// entirely rather than leaving an empty bar.
    var body: some View {
        if isIdle {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Divider()
                statusContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.mode {
        case .caches:
            statusContent(for: viewModel.scanState, stoppedLabel: "Scan stopped")
        case .files:
            statusContent(for: finderViewModel.state, stoppedLabel: "Search stopped")
        case .uninstall:
            uninstallStatusContent
        }
    }

    /// The Uninstall sweep has its own phase shape (`UninstallPhase`) —
    /// per-identity, not per-path — so it gets its own tray rather than
    /// being forced through `statusContent(for:stoppedLabel:)`, which reads
    /// `ScanState`.
    @ViewBuilder
    private var uninstallStatusContent: some View {
        if uninstallViewModel.isSweeping {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(uninstallViewModel.currentPhaseDescription ?? "Sweeping…")
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else if let report = uninstallViewModel.report {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    // A sweep that could not read the whole disk must not
                    // render the same unconditional green checkmark as one
                    // that did — that would assert a completeness this
                    // sweep never checked, the one thing `ScanCompleteness`
                    // exists to prevent (see its own doc comment).
                    Image(systemName: report.completeness.isExact
                        ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(report.completeness.isExact ? .green : .orange)
                        .help(completenessHelp(report.completeness))
                    Text(UninstallWording.sweptRowsText(
                        listedRowCount: uninstallViewModel.listedRowCount,
                        completeness: report.completeness))
                        .font(.caption)
                }
                caveatText(report.completeness)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// One tray for both modes. The two differed only in the word used for a
    /// stopped run, and keeping two copies meant a fix to one silently skipped
    /// the other — which is how the Caches tray kept its unguarded "0 items
    /// found (Zero KB)" long after the Files tray had a type dedicated to
    /// suppressing exactly that.
    @ViewBuilder
    private func statusContent(for state: ScanState, stoppedLabel: String) -> some View {
        VStack(spacing: 8) {
            switch state {
            case .idle:
                EmptyView()

            case .scanning(let path, let items, let bytes):
                VStack(alignment: .leading, spacing: 4) {
                    // Spinner beside its label, not stacked above it. An
                    // indeterminate spinner is an adornment on the text, unlike
                    // the determinate bar in `.measuring`, which spans the tray.
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        if let items, let bytes {
                            Text("\(items) items found (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))")
                                .font(.caption)
                        } else {
                            Text("Searching…")
                                .font(.caption)
                        }
                    }
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

            case .measuring(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .controlSize(.small)
                    Text("Measuring \(progress.completed) of \(progress.total)")
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

            case .completed(let total, let bytes, let duration, let completeness):
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: completeness.isExact
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(completeness.isExact ? .green : .orange)
                            .help(completenessHelp(completeness))
                        Text("\(total) items \u{2022} \(totalText(bytes, completeness)) \u{2022} \(String(format: "%.1fs", duration))")
                            .font(.caption)
                    }
                    caveatText(completeness)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

            case .cancelled(let items, let bytes, let completeness):
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.orange)
                            .help(ReadoutHelpTopic.stopped.helpText.short)
                        // A stopped run's total is a floor whatever its
                        // completeness says, because the walk did not finish.
                        Text("\(stoppedLabel) \u{2022} \(items) items \u{2022} \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))+")
                            .font(.caption)
                    }
                    caveatText(completeness)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    /// A "+" suffix marks a total as a floor — `Floor`, the same marker a
    /// single row carries. Takes the completeness rather than a `Bool` so the
    /// polarity cannot be passed the wrong way round.
    private func totalText(_ bytes: Int64, _ completeness: ScanCompleteness) -> String {
        let base = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return Floor.marked(base, completeness)
    }

    @ViewBuilder
    private func caveatText(_ completeness: ScanCompleteness) -> some View {
        if let caveat = completeness.caveat {
            Text(caveat)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                // The line names up to three separate mechanisms in a handful
                // of words. The tooltip is where each one gets defined.
                .help(ReadoutHelpTopic.caveat.helpText.short)
        }
    }

    /// The marker's own meaning, which is otherwise carried entirely by a
    /// colour: green and orange differ by hue and by nothing else on screen.
    /// A stopped run has its own topic and its own glyph — see
    /// `ReadoutHelpTopic.stopped` for why it is a floor for a reason the
    /// other two do not share.
    private func completenessHelp(_ completeness: ScanCompleteness) -> String {
        completeness.isExact
            ? ReadoutHelpTopic.exact.helpText.short
            : ReadoutHelpTopic.incomplete.helpText.short
    }
}
