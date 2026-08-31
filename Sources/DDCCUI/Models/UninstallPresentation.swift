import Foundation
import DDCCCore

/// One row the Uninstall list actually renders — one app identity's whole
/// footprint, or one dead artifact that belongs to no identity at all.
/// Mirrors `UninstallRow` (`DDCCCore`) rather than reusing it directly:
/// this type is `Identifiable` over a stable string id the list and
/// selection state can key on, which `UninstallRow` has no reason to carry
/// into the engine.
public enum UninstallDisplayRow: Identifiable {
    case app(AppFootprint)
    case deadArtifact(FootprintItem)

    public var id: String {
        switch self {
        case .app(let footprint): return "app:" + footprint.identity.bundleID
        case .deadArtifact(let item): return "dead:" + item.id
        }
    }
}

/// One section of the Uninstall list. A structural fact about its rows —
/// "this app is already gone" or "this artifact belongs to no identity" —
/// not a badge on a mixed list. See `UninstallGrouping`.
public struct UninstallSection: Identifiable {
    public let id: String
    public let title: String
    public let rows: [UninstallDisplayRow]

    public init(id: String, title: String, rows: [UninstallDisplayRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// How the two identity sections are ordered.
///
/// Dead artifacts are not sorted by this and never have been — see
/// `sections(for:sort:searchText:)`.
public enum UninstallSortOrder: String, CaseIterable, Sendable, Identifiable {
    /// Total attributable footprint, largest first. The default, and what
    /// the list did before there was a choice.
    case size = "Size"
    /// What the row actually offers, largest first.
    case reclaimable = "Reclaimable"
    /// Display name, A to Z.
    case name = "Name"

    public var id: String { rawValue }
}

/// Splits and orders `UninstallReport.rows` into the sections settled
/// on from mockups:
/// `INSTALLED` and `LEFTOVERS ONLY` are a structural fact about a row, not
/// a badge on a mixed list, so they are two separate sections rather than
/// one sorted list with a tag. Dead artifacts get a third section of their
/// own for the same reason `deadArtifactsAreReachableWithoutSortingBySize`
/// exists: they are near-zero bytes and would sink to the bottom of any
/// size-sorted list, so their value — completeness, not space — needs a
/// section that does not depend on their size to stay visible.
public enum UninstallGrouping {
    public static let installedSectionID = "installed"
    public static let leftoversSectionID = "leftoversOnly"
    public static let deadArtifactsSectionID = "deadArtifacts"

    public static let installedSectionTitle = "INSTALLED"
    public static let leftoversSectionTitle = "LEFTOVERS ONLY — app not on disk"
    public static let deadArtifactsSectionTitle = "DEAD ARTIFACTS"

    /// The metric the default sort uses within the two identity sections:
    /// the whole attributable footprint, reclaimable and retained alike.
    /// A sort key only — this number is never presented to the user as
    /// reclaimable (Rule 2; see `UninstallWording.reclaimableBytes(for:)`,
    /// which is the one function that may be shown as that).
    public static func totalAttributableFootprint(of footprint: AppFootprint) -> Int64 {
        let items = footprint.items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let retained = footprint.retained.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return items + retained
    }

    /// Default sort: total attributable footprint, largest first, within
    /// `INSTALLED` and within `LEFTOVERS ONLY` independently. Dead
    /// artifacts are ordered by name — sorting them by size would defeat
    /// the reason they get their own section in the first place.
    /// `searchText` matches an app's display name or bundle id, and a dead
    /// artifact's display name. The bundle id is included because it is the
    /// only thing that distinguishes some rows from each other — two apps
    /// whose display name is "Helper" differ by nothing else on screen.
    ///
    /// Filtering happens before sections are built, so a section emptied by
    /// a search leaves no heading behind, exactly as one emptied by the
    /// zero-reclaimable filter does.
    public static func sections(
        for rows: [UninstallRow],
        sort: UninstallSortOrder = .size,
        searchText: String = ""
    ) -> [UninstallSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var installed: [AppFootprint] = []
        var leftovers: [AppFootprint] = []
        var deadArtifacts: [FootprintItem] = []

        for row in rows {
            switch row {
            case .app(let footprint):
                // An Apple-owned refusal is permanent, so its row can never
                // be acted on — and the scan roots cover some 220 stock
                // bundles, which would sit ahead of anything the user came
                // for. Dropped here rather than in the engine: the engine's
                // refusal behaviour is correct, and this is presentation.
                //
                // Dropped on permanence, not on size, so it holds even for a
                // footprint carrying bytes.
                if footprint.refusal == .appleOwned { continue }

                // A row offering zero bytes is not something to act on, and
                // this list is for acting on things. Strict, and it has a cost: a row
                // whose whole footprint is retained disappears too, though
                // its bytes are real.
                //
                // `reclaimableBytes`, not the total footprint: the question is
                // what this row offers, which is `items` alone.
                //
                // A refused row survives despite offering zero bytes, because
                // what it offers is an action rather than space — a running app
                // was never measured, and quitting it changes the answer.
                // Hiding it would hide the instruction. Apple-owned rows are
                // already gone above, so every refusal reaching here is
                // transient.
                if footprint.refusal == nil,
                   UninstallWording.reclaimableBytes(for: footprint) == 0 {
                    continue
                }

                if !query.isEmpty,
                   !footprint.identity.displayName.lowercased().contains(query),
                   !footprint.identity.bundleID.lowercased().contains(query) {
                    continue
                }

                if footprint.identity.isPresent {
                    installed.append(footprint)
                } else {
                    leftovers.append(footprint)
                }
            case .deadArtifact(let item):
                // The same rule as an app row: a dead artifact that can be
                // removed and holds zero bytes offers exactly as little.
                if item.sizeBytes == 0 { continue }
                if !query.isEmpty, !item.displayName.lowercased().contains(query) { continue }
                deadArtifacts.append(item)
            }
        }

        installed.sort(by: comparator(for: sort))
        leftovers.sort(by: comparator(for: sort))
        // Not sorted by `sort`. Dead artifacts are near-zero bytes and would
        // sink to the bottom of any size order, which is the whole reason
        // they get a section of their own rather than a badge on a mixed
        // list — see `deadArtifactsAreReachableWithoutSortingBySize`.
        deadArtifacts.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        var sections: [UninstallSection] = []
        if !installed.isEmpty {
            sections.append(UninstallSection(
                id: installedSectionID, title: installedSectionTitle, rows: installed.map(UninstallDisplayRow.app)))
        }
        if !leftovers.isEmpty {
            sections.append(UninstallSection(
                id: leftoversSectionID, title: leftoversSectionTitle, rows: leftovers.map(UninstallDisplayRow.app)))
        }
        if !deadArtifacts.isEmpty {
            sections.append(UninstallSection(
                id: deadArtifactsSectionID, title: deadArtifactsSectionTitle,
                rows: deadArtifacts.map(UninstallDisplayRow.deadArtifact)))
        }
        return sections
    }

    /// Size and reclaimable are genuinely different orders, not two names
    /// for one: a row that retains most of its footprint sorts high by size
    /// and low by what it offers. Keeping both is the same reason Rule 2
    /// keeps the two figures apart — they answer different questions.
    private static func comparator(
        for sort: UninstallSortOrder
    ) -> (AppFootprint, AppFootprint) -> Bool {
        switch sort {
        case .size:
            return { totalAttributableFootprint(of: $0) > totalAttributableFootprint(of: $1) }
        case .reclaimable:
            return {
                UninstallWording.reclaimableBytes(for: $0)
                    > UninstallWording.reclaimableBytes(for: $1)
            }
        case .name:
            return {
                $0.identity.displayName.localizedStandardCompare($1.identity.displayName)
                    == .orderedAscending
            }
        }
    }
}

/// Every word and number the Uninstall view shows, kept as plain functions
/// so `UninstallPresentationTests` can exercise them without evaluating a
/// SwiftUI `body`. The view files are thin renderers over this type.
public enum UninstallWording {

    /// Hover text for the **Reclaimable** figure.
    ///
    /// Two jobs. It says what the number is — and it repeats the Trash
    /// caveat, because this is the one place a user reads a byte figure and
    /// forms an expectation about disk space. A Trash move frees nothing
    /// until the Trash is emptied, so a tooltip on the number itself is the
    /// cheapest place to say so.
    public static let reclaimableHelp =
        "What DDCC would remove for this app. Moving items to the Trash does "
        + "not free the space until the Trash is emptied."

    /// Hover text for the **Retained** figure.
    ///
    /// "Retained" is the term this engine invented; nothing on screen defines
    /// it, and the detail pane's explanation is a pane away from the list row
    /// where the word first appears. Retain-until-last is the behaviour a user
    /// is most likely to read as a bug — bytes attributed to the app they are
    /// removing, deliberately left behind — so the hint has to give the reason,
    /// not just the definition.
    public static let retainedHelp =
        "Attributed to this app, but another product still claims it. Kept "
        + "until every app that claims it is gone."

    /// Rule 1: a Trash move frees nothing until the Trash is emptied — the
    /// same class of claim as the completeness caveat, so "moved", never
    /// "freed".
    public static func trashResultDescription(byteCount: Int64) -> String {
        "Moved \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) to the Trash."
    }

    /// Shown on the one item that macOS will ask the user to authorise.
    ///
    /// Stated on the row rather than only at the moment of the prompt, because
    /// an unexpected password dialog raised by a cleanup tool is alarming in
    /// exactly the way a cleanup tool must not be. The user should know it is
    /// coming, and why, before pressing anything.
    public static let authenticationNotice =
        "Installed for all users — macOS will ask for your password or Touch ID."

    /// The caveat a permanent deletion must carry when the selection contains
    /// an app that can only be moved to the Trash.
    ///
    /// Rather than disabling the button: everything else in the footprint can
    /// still be deleted permanently, and silently leaving the app behind is
    /// the failure this sentence exists to prevent.
    public static func permanentRemovalCaveat(for footprint: AppFootprint) -> String? {
        guard footprint.items.contains(where: { $0.requiresAuthentication }) else { return nil }
        return """
            The app itself can only be moved to the Trash, so it will be skipped. \
            Use Move to Trash to remove it.
            """
    }

    /// A permanent removal must say plainly that it cannot be undone —
    /// there is no Trash to recover it from.
    public static let permanentRemovalWarning =
        "This permanently deletes these items. This action cannot be undone."

    /// Rule 2, at the view layer: the only number a caller may present as
    /// reclaimable. Forwards to `AppFootprint.reclaimableBytes` — items
    /// only, never `retained` — rather than recomputing it, so the view
    /// layer cannot drift from the engine's own arithmetic by summing the
    /// wrong arrays.
    public static func reclaimableBytes(for footprint: AppFootprint) -> Int64 {
        footprint.reclaimableBytes
    }

    /// The other half of a footprint's total: bytes that are real and
    /// attributed but retained for another claimant. Never added into
    /// `reclaimableBytes` above — a caller that wants to show both figures
    /// (an unlabelled combined total on a list row reads as "what I get back",
    /// which overstates it whenever anything is retained) needs this computed
    /// the same disciplined way, not summed ad hoc in a view.
    public static func retainedBytes(for footprint: AppFootprint) -> Int64 {
        footprint.retained.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    /// The qualification `ClaimPopulation.scannedInstalledApps` exists to
    /// carry, finally reaching a user.
    ///
    /// A group container no *scanned* app still claims lands in Reclaimable
    /// with a bare size and a Move to Trash button — but the population that
    /// answer was checked against is the disk scan, and an app on an unmounted
    /// volume cannot be in it. The UI must not say "safe to reclaim"
    /// unqualified for such a row.
    ///
    /// `nil` for every other population: a receipt database with no remaining
    /// claimant is a closed answer, and an unresolvable one always carries a
    /// retainer.
    public static func claimCaveatDescription(for item: FootprintItem) -> String? {
        guard item.claimCaveat == .scannedInstalledApps else { return nil }
        return "Shared data: no app found on this Mac still claims it. "
            + "An app on a disconnected volume could not be checked."
    }

    /// Why a whole footprint was refused, in words. Shared by the list row
    /// and the detail pane rather than duplicated in each, so the two can
    /// never come to disagree about what a refusal means.
    ///
    /// A refused footprint has no measurement at all, so the row that
    /// carries this must show it *instead of* a byte figure, never
    /// alongside a zero — `AppFootprint(items: [], retained: [], refusal:
    /// .appIsRunning)` rendered as "Reclaimable Zero KB" is
    /// indistinguishable from an app genuinely measured at zero, and the
    /// two mean opposite things.
    public static func refusalDescription(for refusal: FootprintRefusal) -> String {
        switch refusal {
        case .appIsRunning:
            return "This app is running right now. Quit it before removing anything it owns."
        case .appleOwned:
            return "This is part of macOS itself. DevDriveCacheClean will not touch it."
        }
    }

    /// The sweep tray's row count. Takes the number of rows the list
    /// actually *shows*, not `UninstallReport.rows.count`: Apple-owned
    /// identities are dropped by `UninstallGrouping.sections(for:)`,
    /// and a count that included them would credit the sweep
    /// with ~220 rows the user cannot see or act on.
    ///
    /// "Listed", not "swept": Apple-owned rows are swept and not counted, and
    /// the zero-reclaimable filter removes most of the rest, so a number
    /// labelled "swept" would state the wrong fact about the run. What the tray
    /// can honestly say is how many rows are in front of you.
    ///
    /// A "+" suffix marks the count as a floor whenever the sweep was not
    /// exact — `Floor`, the same marker the byte totals carry, for the same
    /// reason: a count with no marker reads as complete. Counted rows rather
    /// than bytes, which is why it is the marker that is shared and not the
    /// formatting.
    public static func sweptRowsText(listedRowCount: Int, completeness: ScanCompleteness) -> String {
        let base = Plural.of(listedRowCount, "row") + " listed"
        return Floor.marked(base, completeness)
    }

    /// Rule 4: a retained item names its claimants. "Retained" without
    /// "kept by Affinity Photo, Affinity Designer" is an unexplained
    /// refusal — the whole point of retain-until-last is that the user can
    /// see why.
    public static func retainedDescription(for item: FootprintItem) -> String {
        let claimants = item.retainedFor.sorted().joined(separator: ", ")
        return "Retained — kept by \(claimants)"
    }

    /// Human words for one evidence source. Never derived from
    /// `displayName` — see `recoveryEvidenceDescription(for:)` for the same
    /// rule applied to identity provenance.
    public static func description(for source: EvidenceSource) -> String {
        switch source {
        case .container: return "an app container"
        case .groupContainer: return "a shared group container"
        case .shelf(let name): return "the \(name) shelf"
        case .receipt(let packageID): return "an install receipt (\(packageID))"
        // A cache entry with no `token` key of its own is stored under the
        // empty token, so naming it would print an empty parenthetical for
        // an identifier that does not exist. Under-claims instead — the
        // same fall-through `FootprintAssembler.retainerName` takes.
        case .cask(let token): return token.isEmpty
            ? "a Homebrew cask" : "a Homebrew cask (\(token))"
        case .messagingHost: return "a native-messaging host manifest"
        case .launchAgent: return "a LaunchAgent"
        // Says "known", not "found". Every other phrase here describes
        // something read off the disk; this one describes a location this
        // app was already known to install into, which is a weaker claim and
        // should read as one.
        case .declaredPayload: return "a known install location outside the app"
        case .appBundle: return "the application itself"
        }
    }

    /// Every row states the evidence behind it. For an app row this is
    /// every distinct source across its reclaimable and retained items —
    /// deduplicated by rendered text, since `EvidenceSource` is
    /// `Equatable` but not `Hashable`. For a dead artifact it is the dead
    /// declaration's own target, which is a stronger claim than mere
    /// attribution (see `EvidenceClass`'s own doc comment).
    public static func evidenceStatement(for row: UninstallDisplayRow) -> String {
        switch row {
        case .app(let footprint):
            var seen: [String] = []
            for item in footprint.items + footprint.retained {
                let text = evidenceText(for: item.evidence)
                if !seen.contains(text) { seen.append(text) }
            }
            return seen.isEmpty ? "No evidence recorded." : "From " + seen.joined(separator: ", ")
        case .deadArtifact(let item):
            return evidenceText(for: item.evidence)
        }
    }

    /// The same statement as `evidenceStatement(for:)`, for a single item
    /// rather than a whole row's items — the detail pane lists evidence
    /// per line, not only per app.
    public static func evidenceStatement(for item: FootprintItem) -> String {
        evidenceText(for: item.evidence)
    }

    private static func evidenceText(for evidence: EvidenceClass) -> String {
        switch evidence {
        case .attributed(let source): return description(for: source)
        case .dead(let target):
            return "no longer points to anything that exists "
                + "(\(PathDisplay.tildeAbbreviatedIfAbsolute(target)))"
        }
    }

    /// This is what `BundleIdentity.namespace` is for, and its only reader.
    /// Renders from `namespace`, never by parsing `displayName`,
    /// which is a human name and nothing more.
    ///
    /// Keyed on the namespace alone, never on `isPresent`. Provenance is a fact
    /// about how the identity was recovered, and that does not change when the
    /// product turns out to still be installed: a cask anchored on a matching
    /// `pkgutil` receipt is both present and recovered, and a line keyed on
    /// absence would go silent on exactly the row that most needs to say where
    /// it came from. `.bundleID` is the namespace that means "read off an
    /// installed bundle", and it is the one that returns `nil`.
    public static func recoveryEvidenceDescription(for identity: BundleIdentity) -> String? {
        switch identity.namespace {
        case .packageID: return "from an install receipt"
        case .caskToken: return "from a Homebrew Caskroom entry"
        case .caskReceipt: return "from an install receipt naming a Homebrew cask"
        case .bundleID: return nil
        }
    }

    /// The whole sentence a detail pane renders for a recovered identity, and
    /// the only place the two halves of it are combined.
    ///
    /// The provenance half comes from `recoveryEvidenceDescription(for:)` and
    /// is keyed on namespace alone, so every recovered identity says where it
    /// came from. The "not on disk" half is a separate claim about the product
    /// itself and is keyed on `isPresent`, because a cask anchored on a
    /// matching `pkgutil` receipt is recovered *and* installed: saying it is
    /// gone would contradict both the engine and the present glyph beside it.
    public static func recoveryStatement(for identity: BundleIdentity) -> String? {
        guard let recovery = recoveryEvidenceDescription(for: identity) else { return nil }
        return identity.isPresent
            ? "Recovered \(recovery)."
            : "Not on disk — recovered \(recovery)."
    }

    /// on a Mac with no Homebrew at all, `unavailableSources`
    /// carries both `"Homebrew cask cache"` and `"Homebrew Caskroom"` for
    /// the same single absence — correct in the engine (two mechanisms
    /// really were both unreadable), misleading if rendered as two
    /// independent gaps. Collapsed to one line here; left untouched when
    /// only one of the two is present, since that is not proven to be the
    /// same absence.
    public static func collapsedUnavailableSources(_ sources: [String]) -> [String] {
        let caskCache = "Homebrew cask cache"
        let caskroom = "Homebrew Caskroom"
        guard sources.contains(caskCache), sources.contains(caskroom) else { return sources }
        var collapsed = sources.filter { $0 != caskCache && $0 != caskroom }
        collapsed.append("Homebrew is not installed, so no cask evidence (cache or Caskroom) was available.")
        return collapsed
    }

    /// Rule 3 at the report level, not the per-app level: real disk space
    /// this sweep found and could attribute to no known app. Every app
    /// row's own total still understates the disk this sweep actually
    /// found unless this figure is shown somewhere too — see
    /// `UninstallReport.unattributedBytes`'s own doc comment for how it is
    /// computed and what it deliberately excludes.
    public static func unattributedBytesDescription(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(formatted) found on disk but not attributed to any known app."
    }

    /// The other report-level disclosure: `PathGuard` refusals met while
    /// looking for dead artifacts, which belong to no app row and so could
    /// never be shown by any detail pane (see
    /// `UninstallReport.deadArtifactGuardRefusals`'s own doc comment). No
    /// paths named here, on purpose — that much detail belongs to a
    /// dedicated surface if one is ever built; this is the count that
    /// proves the gap is disclosed rather than silently dropped.
    public static func deadArtifactGuardRefusalsDescription(_ refusals: [DisclosedPath]) -> String? {
        guard !refusals.isEmpty else { return nil }
        let noun = refusals.count == 1 ? "artifact" : "artifacts"
        return "\(refusals.count) dead \(noun), refused by the safety check, outside any app's footprint."
    }
}
