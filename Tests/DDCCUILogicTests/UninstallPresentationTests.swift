import Testing
import Foundation
@testable import DDCCUI
import DDCCCore

// MARK: - Fixture helpers
//
// Sized deliberately: a fixture with one instance of the thing being
// counted cannot detect an off-by-one, and one with zero instances cannot
// detect an overlap. Every fixture below that exercises grouping or
// counting carries at least two instances of the relevant kind.

private func makeIdentity(
    bundleID: String, displayName: String, isPresent: Bool,
    namespace: IdentityNamespace = .bundleID
) -> BundleIdentity {
    BundleIdentity(
        bundleID: bundleID, displayName: displayName, bundleURL: nil,
        isPresent: isPresent, namespace: namespace)
}

private func makeItem(
    path: String, sizeBytes: Int64, source: EvidenceSource,
    retainedFor: Set<String> = [], claimCaveat: ClaimPopulation? = nil,
    displayName: String? = nil
) -> FootprintItem {
    let url = URL(fileURLWithPath: path)
    return FootprintItem(
        path: url, sizeBytes: sizeBytes, evidence: .attributed(source), sources: [source],
        retainedFor: retainedFor, claimCaveat: claimCaveat,
        displayName: displayName ?? url.lastPathComponent)
}

private func makeDeadItem(
    path: String, sizeBytes: Int64, target: String, displayName: String
) -> FootprintItem {
    FootprintItem(
        path: URL(fileURLWithPath: path), sizeBytes: sizeBytes,
        evidence: .dead(target: target), sources: [.launchAgent],
        retainedFor: [], claimCaveat: nil, displayName: displayName)
}

private func makeRefusedFootprint(
    bundleID: String, displayName: String, refusal: FootprintRefusal
) -> AppFootprint {
    AppFootprint(
        identity: makeIdentity(bundleID: bundleID, displayName: displayName, isPresent: true),
        items: [], retained: [], disclosedOutsideAllowlist: [], refusedByPathGuard: [],
        refusal: refusal)
}

private func makeFootprint(
    identity: BundleIdentity, items: [FootprintItem] = [], retained: [FootprintItem] = []
) -> AppFootprint {
    AppFootprint(
        identity: identity, items: items, retained: retained,
        disclosedOutsideAllowlist: [], refusedByPathGuard: [], refusal: nil)
}

/// Records calls made from a `@Sendable` seam. A plain captured `var` cannot
/// be mutated from one, and making the seam non-sendable to suit a test would
/// be the test dictating the production type.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, Bool)] = []

    func record(_ bundleID: String, _ force: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.append((bundleID, force))
    }

    var calls: [(String, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Rule 1: never say "freed"

/// A Trash move frees nothing until the Trash is emptied, so the UI must
/// not say "freed". This is the same class of claim as the completeness
/// caveat: the number has to mean what it says.
@Test func aTrashMoveIsDescribedAsMovedNotFreed() {
    let description = UninstallWording.trashResultDescription(byteCount: 42_000_000)
    #expect(description.localizedCaseInsensitiveContains("move"))
    #expect(!description.localizedCaseInsensitiveContains("freed"))
}

@Test func aPermanentRemovalStatesThatItCannotBeUndone() {
    #expect(UninstallWording.permanentRemovalWarning.localizedCaseInsensitiveContains("cannot be undone"))
}

// MARK: - Rule 2, at the view layer: reclaimable never absorbs retained

/// The view-layer number a caller may present as reclaimable must equal
/// `AppFootprint.reclaimableBytes` — items only, never `retained`. Sized so
/// the retained bytes dwarf the items bytes: a mutant that adds `retained`
/// in would move this number by an order of magnitude, not a rounding
/// error a loose assertion could miss.
@Test func theReclaimableTotalNeverIncludesRetainedBytes() {
    let footprint = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.retain", displayName: "Retain Test", isPresent: true),
        items: [
            makeItem(path: "/Users/x/Library/Containers/retain-item", sizeBytes: 1_000_000, source: .container)
        ],
        retained: [
            makeItem(
                path: "/Users/x/Library/Group Containers/retain-shared", sizeBytes: 9_000_000,
                source: .groupContainer, retainedFor: ["Other App"])
        ])

    #expect(UninstallWording.reclaimableBytes(for: footprint) == 1_000_000)
}

// MARK: - Dead artifacts stay reachable

/// Dead artifacts are near-zero bytes and sort to the bottom of a
/// size-ordered list. Their value is completeness, not space, so the list
/// must be able to surface them regardless of size.
@Test func deadArtifactsAreReachableWithoutSortingBySize() throws {
    let bigApp = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.big", displayName: "Big App", isPresent: true),
        items: [makeItem(path: "/Users/x/Library/Containers/big", sizeBytes: 5_000_000_000, source: .container)])
    let mediumApp = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.medium", displayName: "Medium App", isPresent: true),
        items: [makeItem(path: "/Users/x/Library/Containers/medium", sizeBytes: 1_000_000_000, source: .container)])

    // Names deliberately out of size order (900, 100, 300 bytes) so a
    // section sorted alphabetically proves the sort key is not size.
    let deadArtifacts = [
        makeDeadItem(
            path: "/Users/x/Library/LaunchAgents/zeta.plist", sizeBytes: 300,
            target: "/gone/zeta", displayName: "Zeta"),
        makeDeadItem(
            path: "/Users/x/Library/LaunchAgents/alpha.plist", sizeBytes: 900,
            target: "/gone/alpha", displayName: "Alpha"),
        makeDeadItem(
            path: "/Users/x/Library/LaunchAgents/mid.plist", sizeBytes: 100,
            target: "/gone/mid", displayName: "Mid")
    ]

    let rows: [UninstallRow] = [.app(bigApp), .app(mediumApp)] + deadArtifacts.map(UninstallRow.deadArtifact)
    let sections = UninstallGrouping.sections(for: rows)

    let deadSection = try #require(sections.first { $0.id == UninstallGrouping.deadArtifactsSectionID })
    let deadNames = deadSection.rows.map { row -> String in
        guard case .deadArtifact(let item) = row else { return "" }
        return item.displayName
    }

    // Alphabetical (Alpha, Mid, Zeta), not size order (Alpha=900, Zeta=300, Mid=100).
    #expect(deadNames == ["Alpha", "Mid", "Zeta"])
    #expect(deadSection.rows.count == 3)
}

// MARK: - Retained items name their claimants

@Test func aRetainedSharedItemNamesTheAppsThatKeepIt() {
    let item = makeItem(
        path: "/Users/x/Library/Group Containers/group.affinity", sizeBytes: 2_000_000,
        source: .groupContainer, retainedFor: ["Affinity Photo", "Affinity Designer"])

    let description = UninstallWording.retainedDescription(for: item)

    #expect(description.contains("Affinity Photo"))
    #expect(description.contains("Affinity Designer"))
}

// MARK: - Every row states its evidence

@Test func everyRowStatesTheEvidenceBehindIt() {
    let appFootprint = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.evidence", displayName: "Evidenced", isPresent: true),
        items: [
            makeItem(path: "/Users/x/Library/Containers/evidence", sizeBytes: 400_000, source: .container),
            makeItem(
                path: "/Users/x/Library/Application Support/Evidence", sizeBytes: 100_000,
                source: .receipt(packageID: "com.example.evidence.pkg"))
        ])
    let appStatement = UninstallWording.evidenceStatement(for: .app(appFootprint))
    #expect(appStatement.contains("app container"))
    #expect(appStatement.contains("com.example.evidence.pkg"))

    let deadItem = makeDeadItem(
        path: "/Users/x/Library/LaunchAgents/gone.plist", sizeBytes: 200,
        target: "/Applications/Gone.app/Contents/MacOS/Gone", displayName: "Gone")
    let deadStatement = UninstallWording.evidenceStatement(for: .deadArtifact(deadItem))
    #expect(deadStatement.contains("no longer points"))
    #expect(deadStatement.contains("/Applications/Gone.app/Contents/MacOS/Gone"))
}

// MARK: - absent identities get their own section

/// Structure, not decoration: a row for an app that is gone is not a
/// styled variant of an installed one.
///
/// `installedSmall`'s `retained` item is load-bearing, not incidental: it
/// makes this fixture's total-attributable order (small first, 10,000,000
/// > 9,000,000) disagree with its reclaimable-only order (big first,
/// 9,000,000 > 1,000,000). Every earlier version of this fixture left
/// `retained` empty on every footprint, so `totalAttributableFootprint` and
/// `reclaimableBytes` produced identical orderings — a mutant that swapped
/// one sort key for the other still passed every test here.
@Test func absentIdentitiesAreGroupedSeparatelyFromInstalledOnes() throws {
    let installedSmall = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.installedsmall", displayName: "Installed Small", isPresent: true),
        items: [makeItem(path: "/Users/x/Library/Containers/installedsmall", sizeBytes: 1_000_000, source: .container)],
        retained: [
            makeItem(
                path: "/Users/x/Library/Group Containers/installedsmall-shared", sizeBytes: 9_000_000,
                source: .groupContainer, retainedFor: ["Other App"])
        ])
    let installedBig = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.installedbig", displayName: "Installed Big", isPresent: true),
        items: [makeItem(path: "/Users/x/Library/Containers/installedbig", sizeBytes: 9_000_000, source: .container)])
    let leftoverSmall = makeFootprint(
        identity: makeIdentity(
            bundleID: "com.example.leftoversmall", displayName: "Leftover Small",
            isPresent: false, namespace: .packageID),
        items: [
            makeItem(
                path: "/Users/x/Library/Application Support/leftoversmall", sizeBytes: 500_000,
                source: .receipt(packageID: "com.example.leftoversmall"))
        ])
    let leftoverBig = makeFootprint(
        identity: makeIdentity(
            bundleID: "com.example.leftoverbig", displayName: "Leftover Big",
            isPresent: false, namespace: .caskToken),
        items: [
            makeItem(
                path: "/Users/x/Library/Application Support/leftoverbig", sizeBytes: 4_000_000,
                source: .cask(token: "leftover-big"))
        ])

    let rows: [UninstallRow] = [.app(installedSmall), .app(installedBig), .app(leftoverSmall), .app(leftoverBig)]
    let sections = UninstallGrouping.sections(for: rows)

    #expect(sections.count == 2)
    let installedSection = try #require(sections.first(where: { $0.id == UninstallGrouping.installedSectionID }))
    let leftoversSection = try #require(sections.first(where: { $0.id == UninstallGrouping.leftoversSectionID }))

    func bundleIDs(_ section: UninstallSection) -> [String] {
        section.rows.compactMap { row -> String? in
            guard case .app(let footprint) = row else { return nil }
            return footprint.identity.bundleID
        }
    }

    // installedSmall sorts first: its total attributable footprint
    // (1,000,000 reclaimable + 9,000,000 retained = 10,000,000) exceeds
    // installedBig's (9,000,000, nothing retained) — the reverse of what
    // sorting by reclaimable bytes alone would produce.
    #expect(bundleIDs(installedSection) == ["com.example.installedsmall", "com.example.installedbig"])
    #expect(bundleIDs(leftoversSection) == ["com.example.leftoverbig", "com.example.leftoversmall"])
    // Installed is structurally first, not merely first by luck of sort.
    #expect(sections.first?.id == UninstallGrouping.installedSectionID)
}

// MARK: - a recovered row names its evidence, from namespace

/// Reads `BundleIdentity.namespace`. A recovered row that cannot say what
/// recovered it is indistinguishable from a guess, which is the thing this
/// engine refuses to be. `displayName` on each fixture is deliberately
/// unrelated to its namespace, so a function that cheated by reading
/// `displayName` instead would fail this.
@Test func aRecoveredRowNamesTheEvidenceThatRecoveredIt() {
    let fromReceipt = makeIdentity(
        bundleID: "com.example.receipt", displayName: "Whatever Name",
        isPresent: false, namespace: .packageID)
    let fromCask = makeIdentity(
        bundleID: "leftover-cask-token", displayName: "Some Other Name",
        isPresent: false, namespace: .caskToken)

    #expect(UninstallWording.recoveryEvidenceDescription(for: fromReceipt) == "from an install receipt")
    #expect(UninstallWording.recoveryEvidenceDescription(for: fromCask) == "from a Homebrew Caskroom entry")

    // An identity read off an installed bundle was never recovered from
    // anything — nothing to explain. `.bundleID` is the namespace that says so;
    // presence is not, since a receipt-anchored cask is both present and
    // recovered.
    let present = makeIdentity(bundleID: "com.example.present", displayName: "Present App", isPresent: true)
    #expect(UninstallWording.recoveryEvidenceDescription(for: present) == nil)
}

/// A cask recovered by matching a `pkgutil` id against an install receipt
/// never reads the Caskroom, so its row must not say it did. The two cask
/// namespaces carry the same kind of identifier and differ only in the
/// evidence that produced them, which is precisely what this line reports.
///
/// Stated for a **present** identity, which is what this arm actually mints: a
/// receipt match is evidence the product is installed. Provenance is a fact
/// about how the identity was recovered, not about whether the product is
/// still here, so keying the line on absence would silence exactly the row it
/// was written for.
@Test func aReceiptAnchoredCaskRowNamesTheReceipt() {
    let fromCaskReceipt = makeIdentity(
        bundleID: "leftover-cask-token", displayName: "Some Other Name",
        isPresent: true, namespace: .caskReceipt)

    #expect(UninstallWording.recoveryEvidenceDescription(for: fromCaskReceipt)
        == "from an install receipt naming a Homebrew cask")
}

/// The whole sentence the detail pane renders, not the clause it embeds.
/// Provenance is keyed on namespace, so both a present and an absent recovered
/// row say where they came from; the "not on disk" claim is keyed on
/// `isPresent`, so a receipt-anchored cask that is both recovered and
/// installed is never described as gone under a glyph saying it is here.
@Test func aPresentRecoveredRowStatesItsProvenanceWithoutClaimingItIsGone() {
    let presentReceiptAnchored = makeIdentity(
        bundleID: "leftover-cask-token", displayName: "Some Other Name",
        isPresent: true, namespace: .caskReceipt)

    let present = UninstallWording.recoveryStatement(for: presentReceiptAnchored)
    #expect(present == "Recovered from an install receipt naming a Homebrew cask.")
    #expect(present?.contains("Not on disk") == false)

    let absentReceipt = makeIdentity(
        bundleID: "com.example.receipt", displayName: "Whatever Name",
        isPresent: false, namespace: .packageID)
    #expect(UninstallWording.recoveryStatement(for: absentReceipt)
        == "Not on disk — recovered from an install receipt.")

    // Read off an installed bundle: recovered from nothing, so no sentence.
    let installed = makeIdentity(
        bundleID: "com.example.present", displayName: "Present App", isPresent: true)
    #expect(UninstallWording.recoveryStatement(for: installed) == nil)
}

// MARK: - one absence, one line

/// On a Mac with no Homebrew at all, `unavailableSources` carries both
/// `"Homebrew cask cache"` and `"Homebrew Caskroom"` for the same single
/// absence — correct in the engine, misleading if rendered as two
/// independent gaps.
@Test func theHomebrewAbsenceCollapsesToOneLine() {
    let collapsed = UninstallWording.collapsedUnavailableSources(["Homebrew cask cache", "Homebrew Caskroom"])
    #expect(collapsed.count == 1)
    #expect(!collapsed.contains("Homebrew cask cache"))
    #expect(!collapsed.contains("Homebrew Caskroom"))

    // Only one of the two gaps present: not proven to be the same
    // absence, so nothing is collapsed, and any unrelated entry survives.
    let partial = UninstallWording.collapsedUnavailableSources(["Homebrew cask cache", "Some Other Source"])
    #expect(partial == ["Homebrew cask cache", "Some Other Source"])
}

// MARK: - The other half of the pair, and the two report-level disclosures

/// `retainedBytes(for:)` had no test at all, which meant nothing pinned it
/// to `retained` rather than to `items`. Sized so the two arrays cannot be
/// confused for one another: a mutant reading `items` returns 1,000,000
/// where this expects 9,000,000, and the deliberate asymmetry is the same
/// one `theReclaimableTotalNeverIncludesRetainedBytes` uses from the other
/// side. Together they pin both directions of the pair whose swap is the
/// overstatement this product exists to avoid.
@Test func theRetainedTotalCountsRetainedItemsAndNothingElse() {
    let footprint = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.retain", displayName: "Retain Test", isPresent: true),
        items: [
            makeItem(path: "/Users/x/Library/Containers/retain-item", sizeBytes: 1_000_000, source: .container)
        ],
        retained: [
            makeItem(
                path: "/Users/x/Library/Group Containers/retain-shared", sizeBytes: 9_000_000,
                source: .groupContainer, retainedFor: ["Other App"]),
            makeItem(
                path: "/Users/x/Library/Group Containers/retain-second", sizeBytes: 500_000,
                source: .groupContainer, retainedFor: ["Third App"]),
        ])

    // Two retained items, so a mutant returning only the first is caught.
    #expect(UninstallWording.retainedBytes(for: footprint) == 9_500_000)

    let nothingRetained = makeFootprint(
        identity: makeIdentity(bundleID: "com.example.clean", displayName: "Clean", isPresent: true),
        items: [makeItem(path: "/Users/x/Library/Containers/clean", sizeBytes: 1_000_000, source: .container)])
    #expect(UninstallWording.retainedBytes(for: nothingRetained) == 0)
}

/// Rule 3 at the report level. Zero unattributed bytes is not a disclosure
/// worth a line, so the function returns `nil` — and a mutant that renders
/// "Zero KB found on disk but not attributed" would be a fabricated gap.
/// Above zero it must carry the figure itself, not just the words.
@Test func unattributedBytesAreDisclosedOnlyWhenThereAreAny() throws {
    #expect(UninstallWording.unattributedBytesDescription(0) == nil)

    let description = try #require(UninstallWording.unattributedBytesDescription(4_000_000))
    #expect(description.localizedCaseInsensitiveContains("not attributed"))
    #expect(description.contains(
        ByteCountFormatter.string(fromByteCount: 4_000_000, countStyle: .file)))
}

/// The second report-level disclosure. Counted, never zero-rendered, and
/// pluralised — with two refusals as well as one, because a fixture with a
/// single instance cannot tell a count from a constant.
@Test func deadArtifactRefusalsAreCountedAndReadAsEnglish() throws {
    #expect(UninstallWording.deadArtifactGuardRefusalsDescription([]) == nil)

    let one = try #require(UninstallWording.deadArtifactGuardRefusalsDescription([
        DisclosedPath(path: "/Users/x/Library/LaunchAgents/a.plist", source: .launchAgent)
    ]))
    #expect(one.contains("1 dead artifact,"))

    let two = try #require(UninstallWording.deadArtifactGuardRefusalsDescription([
        DisclosedPath(path: "/Users/x/Library/LaunchAgents/a.plist", source: .launchAgent),
        DisclosedPath(path: "/Users/x/Library/LaunchAgents/b.plist", source: .launchAgent),
    ]))
    #expect(two.contains("2 dead artifacts,"))

    // No paths named — the count is the disclosure, and naming refused
    // paths here would leak detail this surface never promised.
    #expect(!two.contains("/Users/x"))
}

// MARK: - The claim caveat reaches a user

/// `FootprintItem.claimCaveat` says outright that `.scannedInstalledApps`
/// "must reach the UI as a qualification rather than a green light", and
/// until now nothing outside the engine read the field at all. The item it
/// rides on is offered under **Reclaimable**, with a size and a button, on
/// the strength of an answer checked against the disk scan — a population
/// that cannot see an app on an unmounted volume.
///
/// All three populations are exercised, plus the absent one: a fixture
/// carrying only the caveated case cannot tell this function from one that
/// returns the same line unconditionally.
@Test func aGroupContainerNothingScannedClaimsSaysSoRatherThanReadingAsSafe() throws {
    let caveated = makeItem(
        path: "/Users/x/Library/Group Containers/group.example.shared", sizeBytes: 3_000_000,
        source: .groupContainer, claimCaveat: .scannedInstalledApps)
    let description = try #require(UninstallWording.claimCaveatDescription(for: caveated))
    #expect(description.localizedCaseInsensitiveContains("no app found on this Mac"))
    #expect(description.localizedCaseInsensitiveContains("disconnected volume"))
    // The wording qualifies; it must never read as the green light the
    // engine's own doc comment forbids.
    #expect(!description.localizedCaseInsensitiveContains("safe to reclaim"))

    // A closed population is not a qualification, and neither is no claim.
    #expect(UninstallWording.claimCaveatDescription(for: makeItem(
        path: "/Users/x/Library/Application Support/pkg", sizeBytes: 1_000,
        source: .receipt(packageID: "com.example.pkg"), claimCaveat: .receiptDatabase)) == nil)
    #expect(UninstallWording.claimCaveatDescription(for: makeItem(
        path: "/Users/x/Library/Containers/plain", sizeBytes: 1_000,
        source: .container)) == nil)
}

// MARK: - the rule: a refusal is shown as a refusal, or not at all

/// A refused footprint carries `items: []` and `retained: []`, so before
/// this the row read "No evidence recorded. / Reclaimable Zero KB" —
/// indistinguishable from an app genuinely measured at zero, which means
/// the opposite thing. The distinction draws is permanence.
///
/// An Apple-owned refusal can never change, and the scan roots cover some 220
/// stock bundles, so listing them is unactionable rows ahead of everything the
/// user came for: they are dropped. A running app is transient — quitting it
/// changes the answer — so it stays with its reason.
///
/// Two of each kind, so a filter that drops one and keeps the other cannot
/// pass.
///
/// The drop and the zero-reclaimable filter are kept independently provable:
/// the fixture hands `sections(for:)` an Apple-owned footprint carrying
/// reclaimable bytes, which production cannot produce, precisely so the drop
/// cannot pass on the filter's coat-tails. Delete the `.appleOwned` line and
/// this fails; delete the filter and it still passes.
@Test func appleOwnedRowsLeaveTheListOnPermanenceNotOnSize() throws {
    let ownedButSized = AppFootprint(
        identity: makeIdentity(bundleID: "com.apple.finder", displayName: "Finder", isPresent: true),
        items: [makeItem(path: "/Users/x/Library/Containers/finder", sizeBytes: 5_000, source: .container)],
        retained: [], disclosedOutsideAllowlist: [], refusedByPathGuard: [], refusal: .appleOwned)
    let ownedAndEmpty = makeRefusedFootprint(
        bundleID: "com.apple.mail", displayName: "Mail", refusal: .appleOwned)
    let rows: [UninstallRow] = [
        .app(ownedButSized),
        .app(ownedAndEmpty),
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.example.plain", displayName: "Plain", isPresent: true),
            items: [makeItem(path: "/Users/x/Library/Containers/plain", sizeBytes: 1_000, source: .container)])),
    ]

    let listed = UninstallGrouping.sections(for: rows).flatMap { $0.rows.map(\.id) }
    #expect(!listed.contains("app:com.apple.finder"))
    #expect(!listed.contains("app:com.apple.mail"))
    #expect(listed == ["app:com.example.plain"])
}

/// The refusal reason itself, shared by the list row and the detail pane so
/// the two cannot drift. Both cases carry a reason, including the one the
/// list no longer shows: the detail pane still reaches it through a
/// selection, and an enum case with no words is how a silent blank row
/// appears later.
@Test func everyRefusalCarriesItsReasonInWords() {
    let running = UninstallWording.refusalDescription(for: .appIsRunning)
    #expect(running.localizedCaseInsensitiveContains("running"))
    #expect(running.localizedCaseInsensitiveContains("quit"))

    let apple = UninstallWording.refusalDescription(for: .appleOwned)
    #expect(apple.localizedCaseInsensitiveContains("macOS"))
    #expect(running != apple)
}

/// The tray counts what the list shows, not what the report holds — with
/// Apple-owned rows dropped, `report.rows.count` would credit the sweep
/// with rows the user can neither see nor act on. The "+" suffix marks the
/// count as a floor for an inexact sweep, the same convention the byte
/// totals use.
@Test func theSweptRowCountIsTheListedCountAndMarksAFloor() {
    #expect(
        UninstallWording.sweptRowsText(listedRowCount: 12, completeness: .exact) == "12 rows listed")
    #expect(
        UninstallWording.sweptRowsText(
            listedRowCount: 12,
            completeness: ScanCompleteness(unreadableDirectories: 3, flooredItems: 0, unmeasuredItems: 0))
            == "12 rows listed+")
}

/// `listedRowCount` is what the tray reads, and it must follow the sections
/// rather than the raw report — a mutation to `report.rows.count` returns 5
/// where this expects 3. Two Apple-owned rows leave on permanence, so the
/// tray credits the sweep with fewer rows than it walked, which is why the
/// wording it feeds says "listed" rather than "swept". The running row is
/// counted: it is listed, because quitting it is something the user can do.
@MainActor
@Test func theViewModelCountsListedRowsNotSweptOnes() {
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [
            .app(makeRefusedFootprint(bundleID: "com.apple.finder", displayName: "Finder", refusal: .appleOwned)),
            .app(makeRefusedFootprint(bundleID: "com.apple.mail", displayName: "Mail", refusal: .appleOwned)),
            .app(makeRefusedFootprint(bundleID: "com.google.Chrome", displayName: "Chrome", refusal: .appIsRunning)),
            .app(makeFootprint(
                identity: makeIdentity(bundleID: "com.example.a", displayName: "A", isPresent: true),
                items: [makeItem(path: "/Users/x/Library/Containers/a", sizeBytes: 1_000, source: .container)])),
            .deadArtifact(makeDeadItem(
                path: "/Users/x/Library/LaunchAgents/dead.plist", sizeBytes: 512,
                target: "/Applications/Gone.app", displayName: "dead.plist")),
        ],
        completeness: .exact, unavailableSources: [], unattributedBytes: 0,
        deadArtifactGuardRefusals: []))

    #expect(viewModel.report?.rows.count == 5)
    #expect(viewModel.listedRowCount == 3)
}

// MARK: - Stop

/// `startSweep` created `sweepTask` and nothing ever cancelled it. The
/// machinery underneath already worked — `SizeCalculator` checks
/// `Task.isCancelled`, `SizeCompletenessAccumulator` folds `.cancelled`
/// into `unmeasuredItems`, and `UninstallCoordinator.run`'s loop now checks
/// too — but none of it was reachable without a trigger.
///
/// The seam stands in for the coordinator and reports what it saw: it spins
/// until cancellation arrives (bounded, so a broken `cancelSweep` fails
/// rather than hanging the suite) and returns a report whose completeness
/// records whether it was in fact cancelled.
@MainActor
@Test func stopCancelsTheRunningSweep() async {
    let viewModel = UninstallViewModel()
    viewModel.runSweep = { _ in
        var spins = 0
        while !Task.isCancelled && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        return UninstallReport(
            rows: [], completeness: ScanCompleteness(
                unreadableDirectories: 0, flooredItems: 0,
                unmeasuredItems: Task.isCancelled ? 1 : 0),
            unavailableSources: [], unattributedBytes: 0, deadArtifactGuardRefusals: [])
    }

    viewModel.startSweep()
    viewModel.cancelSweep()

    var waits = 0
    while viewModel.isSweeping && waits < 10_000 {
        await Task.yield()
        waits += 1
    }

    #expect(!viewModel.isSweeping)
    // The cancelled run reported itself incomplete rather than as a
    // smaller exact one.
    #expect(viewModel.report?.completeness.unmeasuredItems == 1)
    #expect(viewModel.report?.completeness.isExact == false)
}

// MARK: - Rows with nothing to reclaim
//
// Decided after driving the shipped app: a row offering
// zero bytes is not something to act on, and the list is for acting on
// things. The informational reading of those rows — what an app owns that
// this engine will not touch — is deferred to a future view rather than
// carried by a list whose whole purpose is removal.
//
// The strict rule's cost is accepted deliberately: both consequences
// are over-hiding a residue, not showing something false.

@Test func aRowWithNothingToReclaimIsNotListed() {
    let rows: [UninstallRow] = [
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.example.real", displayName: "Real", isPresent: true),
            items: [makeItem(path: "/tmp/real/data", sizeBytes: 4_096, source: .container)])),
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.example.empty", displayName: "Empty", isPresent: true),
            items: [])),
    ]

    let listed = UninstallGrouping.sections(for: rows).flatMap(\.rows).map(\.id)
    #expect(listed == ["app:com.example.real"])
}

/// The retained-only row. This is the consequence accepted before
/// choosing the strict rule: an app whose whole footprint is attributed but
/// held until its last claimant goes has real bytes on disk and no row.
@Test func aFootprintThatIsEntirelyRetainedIsNotListed() {
    let identity = makeIdentity(bundleID: "com.example.shared", displayName: "Shared", isPresent: true)
    let rows: [UninstallRow] = [.app(makeFootprint(
        identity: identity, items: [],
        retained: [makeItem(
            path: "/tmp/shared/runtime", sizeBytes: 900_000_000, source: .groupContainer,
            retainedFor: ["Other App"])]))]

    #expect(UninstallGrouping.sections(for: rows).isEmpty)
}

/// **Reversed the same day it shipped.** The strict zero-reclaimable rule
/// hid running apps, and that was the one hidden case the user can actually
/// do something about: a running app is refused because a live process will
/// rewrite what we measured, and quitting it changes the answer. Hiding the
/// row hid the instruction.
///
/// A refused row survives the filter even though it offers zero bytes,
/// because what it offers is an *action*, not space.
@Test func aRunningAppIsListedSoItCanBeQuit() {
    let rows: [UninstallRow] = [.app(makeRefusedFootprint(
        bundleID: "com.example.running", displayName: "Running", refusal: .appIsRunning))]

    #expect(UninstallGrouping.sections(for: rows).flatMap(\.rows).map(\.id)
        == ["app:com.example.running"])
}

/// The exemption is for a refusal, not for emptiness in general. An app that
/// was measured and genuinely offers nothing stays hidden — otherwise this
/// would quietly undo the whole filter.
@Test func aMeasuredButEmptyAppIsStillNotListed() {
    let rows: [UninstallRow] = [.app(makeFootprint(
        identity: makeIdentity(bundleID: "com.example.empty", displayName: "Empty", isPresent: true),
        items: []))]

    #expect(UninstallGrouping.sections(for: rows).isEmpty)
}

@MainActor
@Test func quittingARunningAppAsksTheSystemToTerminateIt() {
    let viewModel = UninstallViewModel()
    // A locked box rather than a captured `var`: the seam is `@Sendable`, so
    // the compiler will not let a concurrently-executing closure mutate one.
    let requested = Recorder()
    viewModel.quitApp = { bundleID, force in
        requested.record(bundleID, force)
        return true
    }
    let footprint = makeRefusedFootprint(
        bundleID: "com.example.running", displayName: "Running", refusal: .appIsRunning)

    viewModel.quit(footprint, force: false)
    viewModel.quit(footprint, force: true)

    #expect(requested.calls.map(\.0) == ["com.example.running", "com.example.running"])
    #expect(requested.calls.map(\.1) == [false, true])
}

/// A quit request that the system refuses must say so rather than leaving
/// the user to wonder — the app is still running and the sweep will still
/// refuse it.
@MainActor
@Test func aRefusedQuitIsReported() {
    let viewModel = UninstallViewModel()
    viewModel.quitApp = { _, _ in false }
    let footprint = makeRefusedFootprint(
        bundleID: "com.example.stubborn", displayName: "Stubborn", refusal: .appIsRunning)

    viewModel.quit(footprint, force: false)

    #expect(viewModel.quitResult(for: footprint)?
        .localizedCaseInsensitiveContains("could not") == true)
}

/// Scoped to the row that asked, like every other per-row result in this
/// view model: selecting a different app must not show it someone else's
/// outcome.
@MainActor
@Test func aQuitResultIsScopedToItsOwnRow() {
    let viewModel = UninstallViewModel()
    viewModel.quitApp = { _, _ in true }
    let quit = makeRefusedFootprint(
        bundleID: "com.example.a", displayName: "A", refusal: .appIsRunning)
    let other = makeRefusedFootprint(
        bundleID: "com.example.b", displayName: "B", refusal: .appIsRunning)

    viewModel.quit(quit, force: false)

    #expect(viewModel.quitResult(for: quit) != nil)
    #expect(viewModel.quitResult(for: other) == nil)
}

/// The rule reaches dead artifacts too, now that they can be removed: a
/// zero-byte artifact offers exactly as little as a zero-byte app row.
@Test func aZeroByteDeadArtifactIsNotListed() {
    let rows: [UninstallRow] = [
        .deadArtifact(makeDeadItem(
            path: "/tmp/dead/empty.plist", sizeBytes: 0, target: "/gone", displayName: "empty.plist")),
        .deadArtifact(makeDeadItem(
            path: "/tmp/dead/real.plist", sizeBytes: 512, target: "/gone", displayName: "real.plist")),
    ]

    let listed = UninstallGrouping.sections(for: rows).flatMap(\.rows).map(\.id)
    #expect(listed == ["dead:" + URL(fileURLWithPath: "/tmp/dead/real.plist").path])
}

/// A section whose every row was filtered away must not leave its heading
/// behind. Already true by construction — `sections(for:)` appends a section
/// only when its array is non-empty — and pinned here because the filter is
/// what makes an empty group reachable at all.
@Test func aSectionEmptiedByTheFilterDoesNotRenderItsTitle() {
    let rows: [UninstallRow] = [
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.example.gone", displayName: "Gone", isPresent: false),
            items: [])),
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.example.here", displayName: "Here", isPresent: true),
            items: [makeItem(path: "/tmp/here/data", sizeBytes: 2_048, source: .container)])),
    ]

    let titles = UninstallGrouping.sections(for: rows).map(\.title)
    #expect(titles == [UninstallGrouping.installedSectionTitle])
}

// MARK: - Search and sort
//
// From use: "Uninstall not having search and sort options available
// on the menu bar is jarring." Caches has both; Files has search. The
// original decision not to give Uninstall a search field reasoned that its
// sections already give the list a structure to scan by eye — true of a
// three-section list, and less true the longer the machine's list of apps.

@Test func sortingByNameOrdersEachSectionIndependently() {
    let rows: [UninstallRow] = [
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.b", displayName: "Zebra", isPresent: true),
            items: [makeItem(path: "/tmp/z", sizeBytes: 9_000, source: .container)])),
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.a", displayName: "Alpha", isPresent: true),
            items: [makeItem(path: "/tmp/a", sizeBytes: 1_000, source: .container)])),
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.g", displayName: "Ghost", isPresent: false),
            items: [makeItem(path: "/tmp/g", sizeBytes: 5_000, source: .container)])),
    ]

    let sections = UninstallGrouping.sections(for: rows, sort: .name)
    #expect(sections[0].rows.map(\.id) == ["app:com.a", "app:com.b"])
    #expect(sections[1].rows.map(\.id) == ["app:com.g"])
}

/// Size and reclaimable are different orders, not two names for one. A row
/// that retains most of its footprint sorts high by size and low by what it
/// offers, and the whole reason Rule 2 keeps the two figures apart is that
/// they answer different questions.
@Test func sortingBySizeAndByReclaimableDisagreeWhenBytesAreRetained() {
    let mostlyRetained = makeFootprint(
        identity: makeIdentity(bundleID: "com.big", displayName: "Big", isPresent: true),
        items: [makeItem(path: "/tmp/big/small", sizeBytes: 1_000, source: .container)],
        retained: [makeItem(
            path: "/tmp/big/held", sizeBytes: 500_000, source: .groupContainer,
            retainedFor: ["Other"])])
    let plainlyOffered = makeFootprint(
        identity: makeIdentity(bundleID: "com.mid", displayName: "Mid", isPresent: true),
        items: [makeItem(path: "/tmp/mid/data", sizeBytes: 100_000, source: .container)])
    let rows: [UninstallRow] = [.app(mostlyRetained), .app(plainlyOffered)]

    #expect(UninstallGrouping.sections(for: rows, sort: .size)[0].rows.map(\.id)
        == ["app:com.big", "app:com.mid"])
    #expect(UninstallGrouping.sections(for: rows, sort: .reclaimable)[0].rows.map(\.id)
        == ["app:com.mid", "app:com.big"])
}

/// Dead artifacts keep their own order whatever the sort says. They are
/// near-zero bytes and would sink to the bottom of any size order, which is
/// the reason `deadArtifactsAreReachableWithoutSortingBySize` exists and the
/// reason they have a section rather than a badge.
@Test func deadArtifactsStayInNameOrderUnderEverySort() {
    let rows: [UninstallRow] = [
        .deadArtifact(makeDeadItem(
            path: "/tmp/dead/zulu.plist", sizeBytes: 900, target: "/gone", displayName: "zulu.plist")),
        .deadArtifact(makeDeadItem(
            path: "/tmp/dead/alpha.plist", sizeBytes: 100, target: "/gone", displayName: "alpha.plist")),
    ]

    for sort in UninstallSortOrder.allCases {
        let section = UninstallGrouping.sections(for: rows, sort: sort)[0]
        #expect(
            section.rows.map(\.id) == [
                "dead:" + URL(fileURLWithPath: "/tmp/dead/alpha.plist").path,
                "dead:" + URL(fileURLWithPath: "/tmp/dead/zulu.plist").path,
            ],
            "dead artifacts reordered under \(sort)")
    }
}

@Test func searchMatchesDisplayNameAndBundleID() {
    let rows: [UninstallRow] = [
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.brave.Browser", displayName: "Brave", isPresent: true),
            items: [makeItem(path: "/tmp/brave", sizeBytes: 1_000, source: .container)])),
        .app(makeFootprint(
            identity: makeIdentity(bundleID: "com.figma.Desktop", displayName: "Figma", isPresent: true),
            items: [makeItem(path: "/tmp/figma", sizeBytes: 1_000, source: .container)])),
    ]

    #expect(UninstallGrouping.sections(for: rows, searchText: "brav").flatMap(\.rows).map(\.id)
        == ["app:com.brave.Browser"])
    // The bundle id is the only place some apps are distinguishable at all —
    // two "Helper" rows differ by nothing else.
    #expect(UninstallGrouping.sections(for: rows, searchText: "figma.Desktop").flatMap(\.rows).map(\.id)
        == ["app:com.figma.Desktop"])
    #expect(UninstallGrouping.sections(for: rows, searchText: "BRAVE").flatMap(\.rows).map(\.id)
        == ["app:com.brave.Browser"])
}

/// A search matching nothing yields no sections, not empty headings.
@Test func aSearchMatchingNothingLeavesNoHeadings() {
    let rows: [UninstallRow] = [.app(makeFootprint(
        identity: makeIdentity(bundleID: "com.a", displayName: "Alpha", isPresent: true),
        items: [makeItem(path: "/tmp/a", sizeBytes: 1_000, source: .container)]))]

    #expect(UninstallGrouping.sections(for: rows, searchText: "nothing matches this").isEmpty)
}

/// Whitespace is not a filter. A field the user tabbed through should not
/// empty the list.
@Test func aBlankSearchFiltersNothing() {
    let rows: [UninstallRow] = [.app(makeFootprint(
        identity: makeIdentity(bundleID: "com.a", displayName: "Alpha", isPresent: true),
        items: [makeItem(path: "/tmp/a", sizeBytes: 1_000, source: .container)]))]

    #expect(UninstallGrouping.sections(for: rows, searchText: "   ").flatMap(\.rows).count == 1)
}

// MARK: - The sidebar's totals
//
// Files and Uninstall report their totals in the sidebar
// the way Caches does. For Uninstall that means summing across rows, and
// The same bytes can legitimately appear
// in two rows — a ghost cask identity and the live app's row are handed the
// same zap paths — filed as harmless on exactly this ground: "Nothing sums
// across rows — no total in this feature adds one row's reclaimable figure
// to another's — so the harm is bounded to a duplicated listing rather than
// an inflated number."
//
// Summing naively would remove that bound and turn a duplicated listing into
// an inflated number, in the one dimension this product's positioning turns
// on. The total is therefore computed over the union of item *paths*, so a
// path claimed by two rows counts once.

@MainActor
@Test func theSidebarTotalCountsABytesClaimedByTwoRowsOnce() {
    let shared = makeItem(path: "/Users/x/Library/Application Support/Shared", sizeBytes: 100_000,
                          source: .cask(token: "ghost"))
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [
            .app(makeFootprint(
                identity: makeIdentity(bundleID: "com.ghost", displayName: "Ghost", isPresent: false),
                items: [shared])),
            .app(makeFootprint(
                identity: makeIdentity(bundleID: "com.live", displayName: "Live", isPresent: true),
                items: [shared])),
        ],
        completeness: .exact, unavailableSources: [], unattributedBytes: 0,
        deadArtifactGuardRefusals: []))

    #expect(viewModel.listedRowCount == 2, "both rows are still listed; only the total dedups")
    #expect(viewModel.sidebarReclaimableBytes == 100_000)
}

@MainActor
@Test func theSidebarKeepsReclaimableAndRetainedApart() {
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [.app(makeFootprint(
            identity: makeIdentity(bundleID: "com.a", displayName: "A", isPresent: true),
            items: [makeItem(path: "/tmp/a/offered", sizeBytes: 7_000, source: .container)],
            retained: [makeItem(
                path: "/tmp/a/held", sizeBytes: 3_000, source: .groupContainer,
                retainedFor: ["Other"])]))],
        completeness: .exact, unavailableSources: [], unattributedBytes: 0,
        deadArtifactGuardRefusals: []))

    // Rule 2 at the sidebar: the two figures are never one number.
    #expect(viewModel.sidebarReclaimableBytes == 7_000)
    #expect(viewModel.sidebarRetainedBytes == 3_000)
}

/// The totals follow the list. A row the filter removed offers the user
/// nothing, so crediting the sidebar with its bytes would promise space no
/// visible row accounts for.
@MainActor
@Test func theSidebarTotalCountsOnlyRowsTheListShows() {
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [
            // Dropped by the list, and carrying bytes, so a total that
            // walked `report.rows` instead of the sections would show
            // 501,000 here.
            .app(AppFootprint(
                identity: makeIdentity(bundleID: "com.apple.finder", displayName: "Finder", isPresent: true),
                items: [makeItem(path: "/tmp/finder", sizeBytes: 500_000, source: .container)],
                retained: [], disclosedOutsideAllowlist: [], refusedByPathGuard: [],
                refusal: .appleOwned)),
            .app(makeFootprint(
                identity: makeIdentity(bundleID: "com.real", displayName: "Real", isPresent: true),
                items: [makeItem(path: "/tmp/real", sizeBytes: 1_000, source: .container)])),
        ],
        completeness: .exact, unavailableSources: [], unattributedBytes: 0,
        deadArtifactGuardRefusals: []))

    #expect(viewModel.sidebarReclaimableBytes == 1_000)
}

@MainActor
@Test func theSidebarShowsNoUninstallTotalBeforeASweep() {
    #expect(UninstallViewModel().sidebarReclaimableText == nil)
}

// MARK: - Removing a dead artifact
//
// Decided after driving the shipped app: rather than hide the dead-artifact section until
// it could be acted on, make it actionable. A dead artifact is already a
// `FootprintItem` — the same type the app rows offer — so `DeletionService`
// takes it unchanged; what was missing was a detail pane to select into and
// a removal path that is not keyed on a bundle identity, which these rows do
// not have.

@MainActor
private func viewModelWithDeadArtifact(
    path: String = "/tmp/dead/agent.plist", sizeBytes: Int64 = 4_096
) -> (UninstallViewModel, FootprintItem) {
    let item = makeDeadItem(
        path: path, sizeBytes: sizeBytes, target: "/Applications/Gone.app",
        displayName: URL(fileURLWithPath: path).lastPathComponent)
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [.deadArtifact(item)], completeness: .exact, unavailableSources: [],
        unattributedBytes: 0, deadArtifactGuardRefusals: []))
    return (viewModel, item)
}

@MainActor
@Test func aDeadArtifactCanBeSelected() {
    let (viewModel, item) = viewModelWithDeadArtifact()
    viewModel.selectedRowID = "dead:" + item.id

    #expect(viewModel.selectedDeadArtifact == item)
    // Never both. The detail column picks one pane by asking each in turn,
    // and a selection answering to both would render whichever is asked
    // first rather than what the user clicked.
    #expect(viewModel.selectedFootprint == nil)
}

@MainActor
@Test func selectingAnAppDoesNotYieldADeadArtifact() {
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [.app(makeFootprint(
            identity: makeIdentity(bundleID: "com.a", displayName: "A", isPresent: true),
            items: [makeItem(path: "/tmp/a", sizeBytes: 1_000, source: .container)]))],
        completeness: .exact, unavailableSources: [], unattributedBytes: 0,
        deadArtifactGuardRefusals: []))
    viewModel.selectedRowID = "app:com.a"

    #expect(viewModel.selectedDeadArtifact == nil)
    #expect(viewModel.selectedFootprint != nil)
}

@MainActor
@Test func movingADeadArtifactToTheTrashRemovesItsRow() {
    let (viewModel, item) = viewModelWithDeadArtifact()
    viewModel.deleteItems = { items, _, _ in
        DeletionReport(
            succeeded: items, failed: [],
            bytesReclaimed: items.reduce(Int64(0)) { $0 + $1.sizeBytes })
    }

    viewModel.moveToTrash(deadArtifact: item)

    #expect(viewModel.sections.isEmpty, "the removed artifact still has a row")
    #expect(viewModel.report?.rows.isEmpty == true)
}

/// A failed removal must leave the row where it is. A row that vanishes on
/// failure tells the user the file is gone when it is still on disk — the
/// same rule the app rows already follow by filtering on `succeeded`.
@MainActor
@Test func aDeadArtifactThatFailedToDeleteKeepsItsRow() {
    let (viewModel, item) = viewModelWithDeadArtifact()
    viewModel.deleteItems = { items, _, _ in
        DeletionReport(
            succeeded: [],
            failed: items.map { DeletionFailure(result: $0, reason: "denied") },
            bytesReclaimed: 0)
    }

    viewModel.moveToTrash(deadArtifact: item)

    #expect(viewModel.sections.flatMap(\.rows).count == 1)
}

/// Rule 1 reaches here too: a Trash move is recorded as moved, never freed,
/// and only when it actually succeeded.
@MainActor
@Test func aDeadArtifactTrashResultIsScopedToTheRowThatCausedIt() {
    let (viewModel, item) = viewModelWithDeadArtifact()
    viewModel.deleteItems = { items, _, _ in DeletionReport(
        succeeded: items, failed: [],
        bytesReclaimed: items.reduce(Int64(0)) { $0 + $1.sizeBytes }) }

    viewModel.moveToTrash(deadArtifact: item)

    #expect(viewModel.lastTrashResultRowID == "dead:" + item.id)
    #expect(viewModel.lastTrashResultBytes == 4_096)
}

/// A permanent deletion is never recorded as a Trash result — its own
/// confirmation already said it cannot be undone, and "moved to the Trash"
/// would be false.
@MainActor
@Test func permanentlyDeletingADeadArtifactRecordsNoTrashResult() {
    let (viewModel, item) = viewModelWithDeadArtifact()
    viewModel.deleteItems = { items, _, _ in DeletionReport(
        succeeded: items, failed: [],
        bytesReclaimed: items.reduce(Int64(0)) { $0 + $1.sizeBytes }) }

    viewModel.removePermanently(deadArtifact: item)

    #expect(viewModel.lastTrashResultRowID == nil)
    #expect(viewModel.sections.isEmpty)
}

/// Removing one artifact leaves the others alone. With one row in the
/// fixture a filter that dropped every dead row would pass.
@MainActor
@Test func removingOneDeadArtifactLeavesTheOthers() {
    let first = makeDeadItem(
        path: "/tmp/dead/one.plist", sizeBytes: 512, target: "/gone", displayName: "one.plist")
    let second = makeDeadItem(
        path: "/tmp/dead/two.plist", sizeBytes: 512, target: "/gone", displayName: "two.plist")
    let viewModel = UninstallViewModel()
    viewModel.finish(UninstallReport(
        rows: [.deadArtifact(first), .deadArtifact(second)], completeness: .exact,
        unavailableSources: [], unattributedBytes: 0, deadArtifactGuardRefusals: []))
    viewModel.deleteItems = { items, _, _ in DeletionReport(
        succeeded: items, failed: [],
        bytesReclaimed: items.reduce(Int64(0)) { $0 + $1.sizeBytes }) }

    viewModel.moveToTrash(deadArtifact: first)

    #expect(viewModel.sections.flatMap(\.rows).map(\.id) == ["dead:" + second.id])
}

// MARK: - a cask with no token of its own

/// A legacy-shaped cache entry carrying an `app` artifact but no `token`
/// key is stored under the empty token, and an app-anchored query hands its
/// declared paths back with that empty token attached. Rendering the token
/// unconditionally puts an empty parenthetical in front of the user — "a
/// Homebrew cask ()" — which names an identifier that does not exist.
///
/// The row under-claims instead, the same way `FootprintAssembler`'s
/// retainer naming falls through an empty token rather than printing it.
@Test func aCaskDeclarationWithNoTokenIsNotNamedByAnEmptyToken() {
    let named = makeItem(path: "/tmp/named", sizeBytes: 1, source: .cask(token: "google-chrome"))
    let untokened = makeItem(path: "/tmp/untokened", sizeBytes: 1, source: .cask(token: ""))

    #expect(UninstallWording.evidenceStatement(for: named) == "a Homebrew cask (google-chrome)")
    #expect(UninstallWording.evidenceStatement(for: untokened) == "a Homebrew cask")
}
