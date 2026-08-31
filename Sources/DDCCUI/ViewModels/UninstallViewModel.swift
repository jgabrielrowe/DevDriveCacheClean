import Foundation
import SwiftUI
import AppKit
import DDCCCore

/// State for the Uninstall view.
///
/// Separate from `AppViewModel` and `FinderViewModel` for the same reason
/// those two are separate from each other: the sweep's lifecycle is its
/// own, and switching modes must never disturb what another mode found.
@Observable
@MainActor
final class UninstallViewModel {
    private(set) var report: UninstallReport?
    private(set) var isSweeping = false
    private(set) var currentPhaseDescription: String?
    var selectedRowID: String?
    /// Set after any deletion, so nothing is discarded silently — same
    /// convention as `AppViewModel.lastDeletionReport` and
    /// `FinderViewModel.lastDeletionReport`.
    var lastDeletionReport: DeletionReport<FootprintItem>?
    /// The identity a Trash move most recently succeeded for, paired with
    /// `lastTrashResultBytes` below. Set only by `moveToTrash`, never by
    /// `removePermanently` — a permanent deletion has its own warning
    /// (`UninstallWording.permanentRemovalWarning`) and must never also
    /// claim a Trash move happened. Scoped to one bundle id, not shown
    /// unconditionally, so selecting a different app after a Trash move
    /// cannot show that app the previous app's result.
    ///
    /// Raw bytes, not the rendered sentence: `UninstallWording.trashResultDescription(byteCount:)`
    /// is called at the view, not here, matching every other wording
    /// function in this feature (`reclaimableBytes(for:)`,
    /// `retainedDescription(for:)`, …) — the view model carries values, the
    /// view renders words, and the words never live only in a place the
    /// call-site guard cannot see.
    private(set) var lastTrashResultRowID: String?
    private(set) var lastTrashResultBytes: Int64?

    private var sweepTask: Task<Void, Never>?
    private let environment: ScanEnvironment

    /// Seam over `DeletionService.delete`, matching the precedent
    /// `AppViewModel.deleteResults` and `FinderViewModel.deleteFiles` set: a
    /// test can inject a report without touching the real filesystem.
    /// Asks the system to terminate every running instance of a bundle id,
    /// gracefully or by force, answering whether the request was accepted.
    ///
    /// A seam rather than a direct `NSRunningApplication` call so a test can
    /// exercise the wiring without terminating anything on the machine
    /// running it — the same reason `deleteItems` is injectable.
    ///
    /// "Accepted" is not "terminated": `terminate()` asks politely and an app
    /// may put up a save dialog and stay running, which is why the sweep must
    /// be re-run rather than the row updated optimistically.
    var quitApp: @Sendable (String, Bool) -> Bool = { bundleID, force in
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return true }
        return running.allSatisfy { force ? $0.forceTerminate() : $0.terminate() }
    }

    var deleteItems: @Sendable ([FootprintItem], Bool, PathGuard.Context) -> DeletionReport<FootprintItem> =
        { items, permanently, context in DeletionService.delete(items, permanently: permanently, in: context) }

    /// Seam over `UninstallCoordinator().run`, so a test can drive
    /// `startSweep()`/`finish(_:)` without a real disk sweep — same
    /// precedent as the seam above.
    var runSweep: @Sendable (@escaping @Sendable (UninstallPhase) -> Void) async -> UninstallReport = { onPhase in
        await UninstallCoordinator().run(onPhase: onPhase)
    }

    init(environment: ScanEnvironment = .live()) {
        self.environment = environment
    }

    /// Filter text from the window's search field, and the order the two
    /// identity sections are shown in. Both live here rather than in the
    /// view so `sections` is one derivation with no second copy of the
    /// rules — the same reason `AppViewModel` owns the Caches sort.
    var searchText: String = ""
    var sortOrder: UninstallSortOrder = .size

    var sections: [UninstallSection] {
        UninstallGrouping.sections(
            for: report?.rows ?? [], sort: sortOrder, searchText: searchText)
    }

    /// How many rows the list actually shows. Not `report.rows.count`:
    /// `UninstallGrouping.sections(for:)` drops Apple-owned identities,
    /// and the tray must count what is listed rather than
    /// crediting the sweep with ~220 rows the user can neither see nor act
    /// on.
    var listedRowCount: Int {
        sections.reduce(0) { $0 + $1.rows.count }
    }

    // MARK: - The sidebar's totals
    //
    // Summed over the union of item *paths*, not over rows. The same bytes
    // can legitimately appear in two rows — a ghost cask identity and the
    // live app's row can be handed the same zap paths — and that is
    // harmless on the explicit ground that
    // "nothing sums across rows". A naive sum here would remove that bound
    // and turn a duplicated listing into an inflated number, which is the
    // one kind of error this product's positioning cannot absorb.
    //
    // Scoped to what the list shows, for the same reason `listedRowCount`
    // is: crediting the sidebar with bytes from a row the filter removed
    // would promise space no visible row accounts for.

    /// Which of a footprint's two disjoint buckets a total is drawn from.
    /// Named rather than passed as a closure so the dead-artifact branch can
    /// ask which one it is looking at — an artifact belongs to the
    /// reclaimable side and to nothing else, since it has no claimant that
    /// could retain it.
    private enum Bucket {
        case reclaimable
        case retained
    }

    private func dedupedBytes(_ bucket: Bucket) -> Int64 {
        var seen: Set<String> = []
        var total: Int64 = 0
        for section in sections {
            for row in section.rows {
                switch row {
                case .app(let footprint):
                    let items = bucket == .reclaimable ? footprint.items : footprint.retained
                    for item in items where seen.insert(item.id).inserted {
                        total += item.sizeBytes
                    }
                case .deadArtifact(let item):
                    guard bucket == .reclaimable else { continue }
                    if seen.insert(item.id).inserted { total += item.sizeBytes }
                }
            }
        }
        return total
    }

    var sidebarReclaimableBytes: Int64 { dedupedBytes(.reclaimable) }
    var sidebarRetainedBytes: Int64 { dedupedBytes(.retained) }

    /// `nil` before a sweep, so the sidebar shows a figure only once there
    /// is a run behind it. A "Zero KB" beside Uninstall on launch would be
    /// a measurement nobody took.
    var sidebarReclaimableText: String? {
        guard report != nil else { return nil }
        return ByteCountFormatter.string(fromByteCount: sidebarReclaimableBytes, countStyle: .file)
    }

    /// Shown only when there is something retained, and always under its own
    /// label — never folded into the figure above it.
    var sidebarRetainedText: String? {
        guard report != nil, sidebarRetainedBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sidebarRetainedBytes, countStyle: .file)
    }

    /// the same single Homebrew absence collapsed to one line.
    var displayUnavailableSources: [String] {
        UninstallWording.collapsedUnavailableSources(report?.unavailableSources ?? [])
    }

    var selectedFootprint: AppFootprint? {
        guard let selectedRowID else { return nil }
        for section in sections {
            for row in section.rows {
                if case .app(let footprint) = row, row.id == selectedRowID {
                    return footprint
                }
            }
        }
        return nil
    }

    /// The dead artifact the selection names, if it names one.
    ///
    /// A selection can answer to exactly one of these two — the ids are
    /// prefixed `app:` and `dead:` by `UninstallDisplayRow.id` — and the
    /// detail column asks each in turn. Were both to answer, it would render
    /// whichever it asked first rather than what the user clicked.
    var selectedDeadArtifact: FootprintItem? {
        guard let selectedRowID else { return nil }
        for section in sections {
            for row in section.rows {
                if case .deadArtifact(let item) = row, row.id == selectedRowID {
                    return item
                }
            }
        }
        return nil
    }

    // MARK: - Sweeping

    func startSweep() {
        guard sweepTask == nil else { return }
        isSweeping = true
        currentPhaseDescription = "Starting…"
        lastDeletionReport = nil
        lastTrashResultRowID = nil
        lastTrashResultBytes = nil

        let runSweep = self.runSweep
        sweepTask = Task { [weak self] in
            let onPhase: @Sendable (UninstallPhase) -> Void = { phase in
                Task { @MainActor in self?.apply(phase) }
            }
            let report = await runSweep(onPhase)
            await MainActor.run {
                guard let self else { return }
                self.finish(report)
                self.sweepTask = nil
            }
        }
    }

    /// What makes the cancellation machinery reachable. `SizeCalculator` and
    /// `UninstallCoordinator.run`'s per-identity loop both check
    /// `Task.isCancelled`, and neither check can fire unless something calls
    /// `cancel()`. Same shape as `AppViewModel.cancelScan` and
    /// `FinderViewModel.cancelFind`.
    ///
    /// `sweepTask` is deliberately left non-nil: the cancelled task still
    /// runs to completion and delivers its partial report through
    /// `finish(_:)`, which is what clears it. Nilling it here would let a
    /// second Stop-then-Sweep start a concurrent sweep.
    func cancelSweep() {
        sweepTask?.cancel()
    }

    private func apply(_ phase: UninstallPhase) {
        switch phase {
        case .assembling(let bundleID):
            currentPhaseDescription = "Analyzing \(bundleID)…"
        case .scanningForDeadArtifacts:
            currentPhaseDescription = "Scanning for dead artifacts…"
        }
    }

    /// Internal, not private: a test drives this directly, matching
    /// `AppViewModel.finish` and `FinderViewModel.finish`.
    func finish(_ report: UninstallReport) {
        self.report = report
        isSweeping = false
        currentPhaseDescription = nil
        // A selection that no longer names a row in the fresh report is a
        // selection pointing at nothing.
        let liveIDs = Set(UninstallGrouping.sections(for: report.rows).flatMap { $0.rows.map(\.id) })
        if let selectedRowID, !liveIDs.contains(selectedRowID) {
            self.selectedRowID = nil
        }
    }

    // MARK: - Quitting a running app
    //
    // A running app's footprint is refused outright: a live process rewrites
    // the state we would measure, and a partial footprint of a live app
    // invites removing the half that got through. The refusal is *transient*,
    // which is what makes it worth a control — quitting the app and sweeping
    // again produces a real answer.

    private(set) var lastQuitBundleID: String?
    private(set) var lastQuitSucceeded: Bool?

    func quit(_ footprint: AppFootprint, force: Bool) {
        let accepted = quitApp(footprint.identity.bundleID, force)
        lastQuitBundleID = footprint.identity.bundleID
        lastQuitSucceeded = accepted
    }

    /// What to tell the user about their own quit request, scoped to the row
    /// that made it so switching apps cannot show someone else's outcome.
    ///
    /// Deliberately does not claim the app has quit. `terminate()` asks, and
    /// an app with unsaved work may answer with a save dialog and keep
    /// running; only a fresh sweep can say what is true now.
    func quitResult(for footprint: AppFootprint) -> String? {
        guard lastQuitBundleID == footprint.identity.bundleID,
              let succeeded = lastQuitSucceeded
        else { return nil }
        return succeeded
            ? "Quit requested. Sweep again to measure what \(footprint.identity.displayName) leaves behind."
            : "\(footprint.identity.displayName) could not be asked to quit. Quit it yourself, then sweep again."
    }

    // MARK: - Removal
    //
    // the action acts on exactly one row at a time — for an app,
    // its `items` and never its `retained`, which `DeletionService` would
    // refuse anyway (`FootprintItem.isDeletable` is false for anything with
    // a claimant) but which must never even be offered.
    //
    // Dead artifacts take this path too: they are `FootprintItem`s like any
    // other, so `DeletionService` needs no special case — only a target that
    // is not an app identity.

    /// What one removal acts on. A named type rather than two near-identical
    /// methods, so the byte accounting, the `PathGuard` context and the
    /// row pruning cannot drift between the app case and the dead case.
    private enum RemovalTarget {
        case app(AppFootprint)
        case deadArtifact(FootprintItem)

        /// Never `retained`, for the app case. See above.
        var items: [FootprintItem] {
            switch self {
            case .app(let footprint): return footprint.items
            case .deadArtifact(let item): return [item]
            }
        }

        /// The same id the list and the selection use, so a result shown
        /// under a row is shown under the row that caused it.
        var rowID: String {
            switch self {
            case .app(let footprint): return UninstallDisplayRow.app(footprint).id
            case .deadArtifact(let item): return UninstallDisplayRow.deadArtifact(item).id
            }
        }
    }

    func moveToTrash(_ footprint: AppFootprint) {
        remove(.app(footprint), permanently: false)
    }

    func removePermanently(_ footprint: AppFootprint) {
        remove(.app(footprint), permanently: true)
    }

    func moveToTrash(deadArtifact item: FootprintItem) {
        remove(.deadArtifact(item), permanently: false)
    }

    func removePermanently(deadArtifact item: FootprintItem) {
        remove(.deadArtifact(item), permanently: true)
    }

    /// The paths this removal declares to `PathGuard`, which bypasses
    /// containment and depth for them and for nothing else.
    ///
    /// Two kinds qualify, and both for the same reason: the assembler offered
    /// them from outside the scan root, so an undeclared re-check at deletion
    /// time refuses what the interface has already promised. `.appBundle`
    /// lives in `/Applications`; `.declaredPayload` lives wherever a vendor
    /// put it, `/Users/Shared` in the measured case.
    ///
    /// Narrow on purpose. Only paths THIS sweep attributed as one of those two
    /// kinds, never the whole item set: an ordinary shelf path is already
    /// inside the root and declaring it would widen the bypass for nothing. A
    /// symlink, a root-owned path or `/Applications` itself is still refused,
    /// because a declaration excuses containment alone.
    /// nonisolated: it is a pure function of its argument, and the view model
    /// is `@MainActor`. Without this a test could not call it off the main
    /// actor, which is the whole reason it was lifted out of `remove`.
    nonisolated static func declaredPathsForDeletion(_ items: [FootprintItem]) -> Set<String> {
        Set(
            items
                .filter {
                    $0.sources.contains(.appBundle) || $0.sources.contains(.declaredPayload)
                }
                .map { Candidate.normalizedPathKey(for: $0.path) })
    }

    private func remove(_ target: RemovalTarget, permanently: Bool) {
        // `DeletionService` re-runs `PathGuard` immediately before removing
        // anything, with this context. The app's own `.app` lives outside the
        // scan root — `/Applications`, not `~/Library` — so without declaring
        // it, containment would refuse at deletion time every bundle the
        // assembler had already offered. Every offer would be a promise the
        // deletion breaks.
        //
        // Declared narrowly: only the paths this sweep itself attributed as a
        // bundle (`.appBundle`), never the whole item set. A declaration
        // bypasses containment and depth and nothing else, so a symlink, a
        // root-owned bundle or `/Applications` itself is still refused here,
        // and `FootprintAssembler.appBundleOutcome` builds its verdict from
        // the same declaration so the two cannot diverge.
        let context = PathGuard.Context(
            scanRoot: environment.libraryURL.deletingLastPathComponent(),
            declaredPaths: Self.declaredPathsForDeletion(target.items))
        let result = deleteItems(target.items, permanently, context)
        lastDeletionReport = result

        // Rule 1: never say "freed" — only record what moved, and only
        // for a Trash move that actually succeeded. A permanent deletion
        // is never recorded here; its own confirmation already stated it
        // cannot be undone. The wording itself is rendered by the view —
        // see `lastTrashResultBytes`'s own doc comment for why.
        if !permanently, !result.succeeded.isEmpty {
            lastTrashResultRowID = target.rowID
            lastTrashResultBytes = result.succeeded.reduce(Int64(0)) { $0 + $1.sizeBytes }
        } else if !permanently {
            lastTrashResultRowID = nil
            lastTrashResultBytes = nil
        }

        guard let report else { return }
        let succeededIDs = Set(result.succeeded.map(\.id))
        // Only what actually succeeded. A row that vanished on a failed
        // removal would tell the user the file is gone while it is still on
        // disk.
        guard !succeededIDs.isEmpty else { return }

        let updatedRows: [UninstallRow]
        switch target {
        case .app(let footprint):
            updatedRows = report.rows.map { row -> UninstallRow in
                guard case .app(let candidate) = row,
                      candidate.identity.bundleID == footprint.identity.bundleID
                else { return row }
                let remaining = candidate.items.filter { !succeededIDs.contains($0.id) }
                return .app(AppFootprint(
                    identity: candidate.identity, items: remaining, retained: candidate.retained,
                    disclosedOutsideAllowlist: candidate.disclosedOutsideAllowlist,
                    refusedByPathGuard: candidate.refusedByPathGuard, refusal: candidate.refusal))
            }
        case .deadArtifact:
            // A dead artifact is its whole row, so it goes rather than
            // shrinking. Filtered by item id, not by the target, so removing
            // one artifact cannot take its neighbours with it.
            updatedRows = report.rows.filter { row in
                guard case .deadArtifact(let item) = row else { return true }
                return !succeededIDs.contains(item.id)
            }
        }

        self.report = UninstallReport(
            rows: updatedRows, completeness: report.completeness,
            unavailableSources: report.unavailableSources, unattributedBytes: report.unattributedBytes,
            deadArtifactGuardRefusals: report.deadArtifactGuardRefusals)

        // A row emptied by its own removal leaves the list — an app with
        // nothing left to reclaim is filtered out exactly as a removed
        // artifact is — so a selection naming it now points at nothing.
        let liveIDs = Set(sections.flatMap { $0.rows.map(\.id) })
        if let selectedRowID, !liveIDs.contains(selectedRowID) {
            self.selectedRowID = nil
        }
    }
}
