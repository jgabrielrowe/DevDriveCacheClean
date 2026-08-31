// Sources/DDCCCore/Uninstall/FootprintSource.swift
import Foundation

/// One piece of evidence that a location on disk belongs to `claimedBy`.
///
/// `path` is always run through `Candidate.normalizedPathKey(for:)` —
/// this project's one path-key derivation — so an `EvidenceItem` produced
/// here compares and dedupes correctly against every other path-keyed
/// structure in the project.
public struct EvidenceItem: Sendable, Equatable {
    public let path: String
    public let source: EvidenceSource
    public let claimedBy: String

    public init(path: String, source: EvidenceSource, claimedBy: String) {
        self.path = path
        self.source = source
        self.claimedBy = claimedBy
    }
}

/// What kind of evidence attributed a path to an app. `.shelf` carries the
/// shelf's directory name (e.g. "Preferences") since a caller may want to
/// show it; `.receipt` and `.cask` exist here only so `EvidenceClass`
/// has one enum to wrap regardless of which layer produced the
/// attribution — see the file-level note on the receipt/cask asymmetry.
///
/// `.launchAgent` labels a dead-artifact row built directly from
/// `~/Library/LaunchAgents`, never from a `FootprintSource`: a broken-pointer
/// plist belongs to no live identity, so no footprint grows one.
public enum EvidenceSource: Sendable, Equatable {
    case container
    case groupContainer
    case shelf(String)
    case receipt(packageID: String)
    case cask(token: String)
    case messagingHost
    case launchAgent
    /// A path named by `DeclaredPayloadSource`'s curated table rather than
    /// found by enumeration -- an app's payload outside `~/Library` and
    /// outside its bundle. Distinguished from the enumerating sources because
    /// it is the one kind of evidence that could name a path an app does not
    /// own, and a reader deciding whether to trust a 43 GB row should be able
    /// to see which kind produced it.
    case declaredPayload

    /// The identity's own `.app`, which is the one path in a footprint that
    /// is not attributed by evidence at all — it *is* the app. Added
    /// when bundle removal shipped; before that an uninstaller
    /// removed everything an app left behind and left the app itself.
    case appBundle
}

/// Which namespace `BundleIdentity.bundleID` actually holds its value from.
///
/// `RecoveredIdentities` mints an identity
/// from a receipt's `packageID` or a cask's token, neither of which is a
/// genuine `CFBundleIdentifier` — `FootprintAssembler.swift`'s own note on
/// package ids and bundle ids being separate namespaces is what this
/// records. `.bundleID` is the default and covers every identity this
/// project minted earlier: one read from `InstalledApps`/Launch
/// Services, backed by a real bundle on disk.
public enum IdentityNamespace: Sendable, Equatable {
    /// A genuine `CFBundleIdentifier`, read from an installed bundle.
    case bundleID
    /// A receipt's `packageID`, reused as `bundleID` because
    /// `FootprintAssembler`'s receipt matching requires exact equality —
    /// see `RecoveredIdentities`.
    case packageID
    /// A Homebrew cask's token — not a bundle id or a package id, the one
    /// identifier a cask record actually carries. Recovered from the
    /// Caskroom: Homebrew's own record of what it installed.
    case caskToken
    /// A Homebrew cask's token, recovered instead from an install receipt
    /// whose package id matches one of the cask's `pkgutil` patterns. The
    /// value is the same kind of identifier as `.caskToken`, so both
    /// anchor a cask query by token; they are separate cases because the
    /// **evidence** differs, and the UI states which source it read.
    case caskReceipt
}

extension IdentityNamespace {
    /// Whether `BundleIdentity.bundleID` holds a Homebrew cask token, so a
    /// cask query about this identity anchors by token rather than by app
    /// bundle filename. True for both cask-recovered cases; the evidence
    /// that recovered them differs, the identifier does not.
    public var holdsCaskToken: Bool {
        switch self {
        case .bundleID, .packageID: return false
        case .caskToken, .caskReceipt: return true
        }
    }
}

/// The one app identity every evidence source is asked about. `isPresent`
/// and `bundleURL` come from `InstalledApps`/Launch Services —
/// this type does not resolve them itself, it only carries what a caller
/// already knows.
public struct BundleIdentity: Sendable {
    public let bundleID: String
    public let displayName: String
    public let bundleURL: URL?
    public let isPresent: Bool

    /// Which namespace `bundleID` above was actually drawn from. Defaults
    /// to `.bundleID` so every construction site holding a real bundle
    /// identifier read from an installed app stays silent about it;
    /// `RecoveredIdentities` is the only caller that names a namespace.
    public let namespace: IdentityNamespace

    public init(
        bundleID: String, displayName: String, bundleURL: URL?, isPresent: Bool,
        namespace: IdentityNamespace = .bundleID
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.isPresent = isPresent
        self.namespace = namespace
    }
}

/// Injected filesystem roots, so every source in this file can be pointed
/// at a fixture tree in tests rather than the real `~/Library`. `libraryURL`
/// is the one thing every shelf, container and messaging-host root derives
/// from; sources compute their own subpaths from it rather than each
/// caching a duplicate.
public struct ScanEnvironment: Sendable {
    public let libraryURL: URL

    public init(libraryURL: URL) {
        self.libraryURL = libraryURL
    }

    /// The real `~/Library` for the current user. Not used by any test in
    /// this file — tests inject a fixture tree instead — but every real
    /// caller needs a way to get the live roots.
    public static func live() -> ScanEnvironment {
        ScanEnvironment(
            libraryURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true))
    }

    var containersURL: URL { libraryURL.appendingPathComponent("Containers", isDirectory: true) }
    var groupContainersURL: URL { libraryURL.appendingPathComponent("Group Containers", isDirectory: true) }
    var applicationSupportURL: URL { libraryURL.appendingPathComponent("Application Support", isDirectory: true) }
    /// Flat, never recursed into beyond its own entries — `UninstallCoordinator`'s
    /// dead-artifact sweep is the only reader.
    var launchAgentsURL: URL { libraryURL.appendingPathComponent("LaunchAgents", isDirectory: true) }
}

/// The shape every evidence source shares: given one app identity, report
/// what on disk is attributable to it. Deliberately narrow — no assembly
/// policy, no deletion, no sizing; `FootprintAssembler` is where
/// several sources' output gets combined into one row.
///
/// Not everything producing evidence conforms to this. `ReceiptStore` and
/// `CaskIndex` are shaped around a package database and a cask index rather
/// than "list what is under this identity's shelves", and the assembler
/// consumes them directly. This protocol covers the three shelf-shaped
/// sources only.
///
/// Every conformance degrades silently: an unreadable directory, an absent
/// root or an unparseable manifest contributes nothing rather than throwing. A
/// partial footprint understates what an app owns; a thrown error would abort
/// the scan over one unreadable sibling.
public protocol FootprintSource: Sendable {
    func evidence(for identity: BundleIdentity, in env: ScanEnvironment) -> [EvidenceItem]
}

/// True when `bundleID` names Apple's own namespace, in any of the three
/// spellings actually found on disk. A bare `com.apple.` prefix is
/// insufficient by itself: measured, `group.com.apple.*` and
/// `groups.com.apple.*` account for a further 181 entries and 18.2 MB of
/// Group Containers that prefix alone misses — the single largest apparent
/// "leftover" class the unfiltered sweep produced on the development
/// machine. Every source in this file calls this once, at the top, against
/// the identity it was asked about — not per matched entry — so Apple's own
/// footprint is refused even when a caller names an Apple identity directly
func isAppleOwned(_ bundleID: String) -> Bool {
    bundleID.hasPrefix("com.apple.")
        || bundleID.hasPrefix("group.com.apple.")
        || bundleID.hasPrefix("groups.com.apple.")
}

/// `Containers` (exact bundle id) and `Group Containers` (team-prefix
/// stripped, then exact match). A stripped group id equalling the querying
/// app's own bundle id is the common, safe case — an app sharing data with
/// its own extensions under a group container named after itself. A group
/// id shared across *different* apps' bundle ids (e.g.
/// `6LVTQB9699.com.seriflabs`, shared by all three Affinity apps, none of
/// whose bundle ids is literally `com.seriflabs`) will not match here by
/// construction; that is deliberate; see `ClaimantIndex`, which
/// resolves those claims via `EntitlementReader` rather than by name.
public struct ContainerSource: FootprintSource {
    public init() {}

    public func evidence(for identity: BundleIdentity, in env: ScanEnvironment) -> [EvidenceItem] {
        guard !isAppleOwned(identity.bundleID) else { return [] }

        var items: [EvidenceItem] = []

        let containerURL = env.containersURL.appendingPathComponent(identity.bundleID, isDirectory: true)
        if FileManager.default.fileExists(atPath: containerURL.path) {
            items.append(EvidenceItem(
                path: Candidate.normalizedPathKey(for: containerURL),
                source: .container,
                claimedBy: identity.bundleID))
        }

        let groupEntries = (try? FileManager.default.contentsOfDirectory(
            at: env.groupContainersURL, includingPropertiesForKeys: nil)) ?? []
        for entry in groupEntries {
            let groupID = ContainerSource.strippedGroupID(from: entry.lastPathComponent)
            guard groupID == identity.bundleID else { continue }
            items.append(EvidenceItem(
                path: Candidate.normalizedPathKey(for: entry),
                source: .groupContainer,
                claimedBy: identity.bundleID))
        }

        return items
    }

    /// Strips a ten-character team-identifier prefix — e.g.
    /// `6LVTQB9699.com.seriflabs` -> `com.seriflabs`. Apple's own
    /// un-prefixed group forms (`group.com.apple.x`, `groups.com.apple.x`)
    /// have no team-id-shaped leading component and pass through unchanged.
    ///
    /// Internal rather than private because `FootprintAssembler` needs the
    /// same stripped form before releasing a shared container. Two spellings of
    /// "strip the team id" that drifted apart would ask about an identifier
    /// nothing is registered under, and a live app would read as absent.
    static func strippedGroupID(from entryName: String) -> String {
        guard let dotIndex = entryName.firstIndex(of: ".") else { return entryName }
        let prefix = entryName[entryName.startIndex..<dotIndex]
        guard prefix.count == 10,
              prefix.allSatisfy({ $0.isASCII && ($0.isNumber || ($0.isUppercase && $0.isLetter)) })
        else {
            return entryName
        }
        return String(entryName[entryName.index(after: dotIndex)...])
    }
}

/// `Preferences`, `Caches`, `HTTPStorages`, `Saved Application State`,
/// `Application Scripts`, `Application Support`, `WebKit` and `Cookies`,
/// matched by **exact bundle id only**. No prefix, no fuzzy match: a `Preferences` entry named
/// `com.foo.bar2.plist` must never match a query for `com.foo.bar`, which is
/// why matching strips a known suffix and then compares the *whole remaining
/// string* rather than checking a prefix.
///
/// `Application Support` is the one shelf whose entries are mostly *not*
/// bundle-id shaped — measured here, 85 of 117 top-level entries are named
/// after a product, and they hold all but 624 KB of 24.55 GB. Those stay
/// unattributed: the exact-match rule reads the 32 that are bundle-id shaped
/// and says nothing about the rest, which is the only claim about this
/// directory that can be made without guessing at ownership. Attributing a
/// product-named entry needs a *declaration* — a cask zap stanza or
/// `DeclaredPayloadSource` — never a name resemblance.
public struct ShelfSource: FootprintSource {
    static let shelfNames = [
        "Preferences", "Caches", "HTTPStorages", "Saved Application State", "Application Scripts",
        "Application Support", "WebKit", "Cookies",
    ]

    /// The eight shelf listings, read once by a caller that will ask about
    /// many identities, or `nil` to read them per query.
    ///
    /// Eight directory listings per identity, across the 100-150 identities a
    /// real sweep reaches, none of which depend on the identity being asked
    /// about. Keyed to the library it was read from and falling back to a live
    /// read if asked about a different one: a stale snapshot answering for the
    /// wrong environment would be a wrong-attribution bug.
    private let snapshot: Snapshot?

    struct Snapshot: Sendable {
        let libraryKey: String
        let entriesByShelf: [String: [URL]]
    }

    public init() { self.snapshot = nil }

    init(snapshot: Snapshot) { self.snapshot = snapshot }

    /// Reads all eight shelves once, for a caller about to ask about many
    /// identities against this same environment.
    static func snapshot(of env: ScanEnvironment) -> Snapshot {
        var entriesByShelf: [String: [URL]] = [:]
        for shelfName in shelfNames {
            let shelfURL = env.libraryURL.appendingPathComponent(shelfName, isDirectory: true)
            entriesByShelf[shelfName] = (try? FileManager.default.contentsOfDirectory(
                at: shelfURL, includingPropertiesForKeys: nil)) ?? []
        }
        return Snapshot(
            libraryKey: Candidate.normalizedPathKey(for: env.libraryURL),
            entriesByShelf: entriesByShelf)
    }

    public func evidence(for identity: BundleIdentity, in env: ScanEnvironment) -> [EvidenceItem] {
        guard !isAppleOwned(identity.bundleID) else { return [] }

        let usable = snapshot.flatMap {
            $0.libraryKey == Candidate.normalizedPathKey(for: env.libraryURL) ? $0 : nil
        }

        var items: [EvidenceItem] = []
        for shelfName in Self.shelfNames {
            let entries: [URL]
            if let usable {
                entries = usable.entriesByShelf[shelfName] ?? []
            } else {
                let shelfURL = env.libraryURL.appendingPathComponent(shelfName, isDirectory: true)
                entries = (try? FileManager.default.contentsOfDirectory(
                    at: shelfURL, includingPropertiesForKeys: nil)) ?? []
            }
            for entry in entries {
                guard ShelfSource.strippedID(from: entry.lastPathComponent) == identity.bundleID else { continue }
                items.append(EvidenceItem(
                    path: Candidate.normalizedPathKey(for: entry),
                    source: .shelf(shelfName),
                    claimedBy: identity.bundleID))
            }
        }
        return items
    }

    /// The one suffix-stripping rule applied identically across all eight
    /// shelves, rather than each shelf hardcoding which suffix it expects —
    /// `Preferences` entries end `.plist`, `Saved Application State`
    /// entries end `.savedState`, `Cookies` entries end `.binarycookies`,
    /// the rest carry no suffix at all.
    private static func strippedID(from filename: String) -> String {
        if filename.hasSuffix(".plist") { return String(filename.dropLast(".plist".count)) }
        if filename.hasSuffix(".savedState") { return String(filename.dropLast(".savedState".count)) }
        if filename.hasSuffix(".binarycookies") { return String(filename.dropLast(".binarycookies".count)) }
        return filename
    }
}

/// The declared target a `DependencyProbe` classification extracted from a
/// manifest or plist, when it managed to extract one at all. Present for
/// `.live` and `.dead` (both required a readable, absolute-path
/// declaration to reach); absent for `.unknown`, where nothing was provable
/// to extract. `MessagingHostSource` reads this rather than re-parsing the
/// manifest itself, so there is exactly one place that knows how to get a
/// declared target out of a manifest.
extension DependencyState {
    var declaredTarget: String? {
        switch self {
        case .live(let target), .dead(let target):
            return target
        case .unknown:
            return nil
        }
    }
}

/// Roots named `NativeMessagingHosts` are **discovered**, not listed by
/// browser, and each manifest under one is attributed to an app **only**
/// by the executable its own declared `path` key names — never by the
/// manifest's filename or its JSON `name` key.
///
/// Both halves are earned by measured false positives:
///
/// - **Discovery, not a browser list.** One machine held 17 manifests across
///   12 profile directories spanning 9 browsers. A hardcoded browser list is
///   stale the day a tenth browser ships one of these directories; walking for
///   the directory name is not.
/// - **Attribution by declared target, never by name.** A manifest named
///   `com.anthropic.claude_code_browser_extension` sits beside `Claude.app`
///   (`com.anthropic.claudefordesktop`) but declares a path outside it,
///   because it belongs to an unrelated CLI. Matching on the shared vendor
///   component would also sweep every `com.google.*` Chrome extension host. A
///   near-identical manifest that *does* declare a path inside `Claude.app` is
///   correctly attributed to it — the declared target is what separates
///   them.
public struct MessagingHostSource: FootprintSource {
    /// How many directory levels below `Application Support` this walks
    /// before giving up. Measured: the deepest real root on this
    /// machine is `Application Support/Google/Chrome/Profile 2/
    /// NativeMessagingHosts`, four levels down; five leaves headroom for an
    /// additional browser profile level without repeating the under-scanning
    /// mistake `maxScanDepth`'s doc explains.
    static let maxDepth = 5

    /// Manifests already discovered and already classified, or `nil` to do
    /// both per query.
    ///
    /// The sweep's dominant cost, and why the option exists: the walk covers
    /// `Application Support` to five levels — thousands of directories — and
    /// re-parses every manifest found. Neither depends on the identity asked
    /// about, while `assemble` runs once per identity, so without this the same
    /// unchanging answer is bought 100-150 times. Keyed to the directory it was
    /// built from and ignored if asked about a different one.
    private let snapshot: Snapshot?

    struct Snapshot: Sendable {
        let applicationSupportKey: String
        let manifests: [ClassifiedManifest]
    }

    /// One native-messaging-host manifest, located once and classified
    /// once. `UninstallCoordinator`'s dead-artifact sweep needs the `.dead`
    /// half and this source needs the declared target; both come from the
    /// same `DependencyProbe.classify` call, so both read it from here
    /// rather than each paying for it.
    struct ClassifiedManifest: Sendable {
        let url: URL
        let state: DependencyState
    }

    public init() { self.snapshot = nil }

    init(snapshot: Snapshot) { self.snapshot = snapshot }

    /// Discovers every `NativeMessagingHosts` root under `applicationSupport`
    /// and classifies every JSON manifest in each — the whole walk, once.
    static func snapshot(under applicationSupport: URL) -> Snapshot {
        var manifests: [ClassifiedManifest] = []
        for root in discoverRoots(under: applicationSupport, remainingDepth: maxDepth) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension.lowercased() == "json" {
                manifests.append(ClassifiedManifest(
                    url: entry, state: DependencyProbe.classify(manifestAt: entry)))
            }
        }
        return Snapshot(
            applicationSupportKey: Candidate.normalizedPathKey(for: applicationSupport),
            manifests: manifests)
    }

    public func evidence(for identity: BundleIdentity, in env: ScanEnvironment) -> [EvidenceItem] {
        guard !isAppleOwned(identity.bundleID), let bundleURL = identity.bundleURL else { return [] }
        let bundleKey = Candidate.normalizedPathKey(for: bundleURL)

        let usable = snapshot.flatMap {
            $0.applicationSupportKey == Candidate.normalizedPathKey(for: env.applicationSupportURL)
                ? $0 : nil
        }
        let manifests = usable?.manifests
            ?? Self.snapshot(under: env.applicationSupportURL).manifests

        var items: [EvidenceItem] = []
        for manifest in manifests {
            guard let target = manifest.state.declaredTarget else { continue }
            let targetKey = Candidate.normalizedPathKey(for: URL(fileURLWithPath: target))
            guard targetKey == bundleKey || targetKey.hasPrefix(bundleKey + "/") else { continue }
            items.append(EvidenceItem(
                path: Candidate.normalizedPathKey(for: manifest.url),
                source: .messagingHost,
                claimedBy: identity.bundleID))
        }
        return items
    }

    /// Walks `root` looking for directories literally named
    /// `NativeMessagingHosts`, to `remainingDepth` levels. Does not
    /// recurse *into* a matched directory — its children are manifest
    /// files, never further roots.
    ///
    /// Internal rather than private: the dead-artifact sweep needs the same
    /// walk to classify every manifest under every discovered root, and a
    /// second implementation of "find every `NativeMessagingHosts` root" would
    /// drift from this one.
    static func discoverRoots(under root: URL, remainingDepth: Int) -> [URL] {
        guard remainingDepth > 0 else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var found: [URL] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if entry.lastPathComponent == "NativeMessagingHosts" {
                found.append(entry)
            } else {
                found.append(contentsOf: discoverRoots(under: entry, remainingDepth: remainingDepth - 1))
            }
        }
        return found
    }
}
