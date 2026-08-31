// Sources/DDCCCore/Uninstall/CaskIndex.swift
import Foundation

/// Homebrew's local cask cache, narrowed to the `zap` paths safe to
/// attribute to a single installed application.
///
/// This closes the biggest attribution gap in the uninstaller's evidence.
/// Bundle-id-keyed shelves are small — on one machine 1.34 GB across 47 apps —
/// while name-keyed `Application Support` holds far more per vendor, and
/// without cask data none of it can be attributed to a specific app. The
/// source is a local file Homebrew already wrote; no network, no `brew`
/// subprocess.
///
/// A cask's `zap` stanza is an author-curated uninstall list written for
/// `brew uninstall --zap`, which removes things in order and treats `rmdir` as
/// "only if now empty". This type has neither, and hands back flat paths a
/// caller will delete outright, so every path is checked against three
/// hazards. The rules are recorded where they are implemented in
/// `zapPaths(forAppBundleNamed:presence:)`: never derive a cask from a path,
/// prefer a cask's most specific declaration over its own broader one, and refuse a
/// path more than one cask independently claims.
public struct CaskIndex: Sendable {

    /// One cask's contribution: every bundle filename its `app` artifact
    /// installs, and the `zap` paths it declares, `~`-expanded and stripped of
    /// glob-bearing entries. A flat list rather than a by-name dictionary,
    /// because answering a query for one app requires seeing every other
    /// cask's declarations — that is what Rule 3 checks.
    ///
    /// `appNames` can be empty: a cask installing via `pkg` has a `zap` stanza
    /// but no `app` artifact. Such a cask is never the answer to an app-shaped
    /// query, but its declared paths still count as someone else's evidence of
    /// a shared directory, so dropping them would blind Rule 3.
    private struct Declaration {
        /// The cask's own name for itself, and an **anchor**: a token-keyed
        /// query, a recovered identity and a `CaskPresence` proof are all
        /// stated in terms of it. A legacy-shape entry carrying no `token`
        /// key is stored here as `""`, which every anchoring query refuses —
        /// see `allTokens()`, `presenceInputs()` and the `forCaskToken:`
        /// lookups. `""` names no cask, so treating it as one fuses every
        /// untokened entry into a single identity — one entry's app artifact
        /// answering for all of them, one entry's receipt patterns anchoring
        /// all of them, and one of them entering `provablyAbsent` as a proof
        /// about all of them. The declarations are still stored, so their
        /// paths keep counting as another product's claim under Rule 3.
        let token: String
        let appNames: Set<String>
        /// `appNames` under `nameKey(_:)`, which is what every query compares
        /// against. Held beside `appNames` rather than replacing it because
        /// matching ignores case and *reporting must not*: a
        /// `CaskDeclaredPath` names the declaring cask's own spelling to a
        /// reader, and folding the case away here would flatten it.
        let nameKeys: Set<String>
        /// Whether every `app` artifact this cask declares became a name
        /// above. False when one could not be read at all, and false when one
        /// names a bundle that lands somewhere no installed-app enumeration
        /// reaches — a Homebrew 6.0 `:target` naming an explicit path rather
        /// than a bare filename. Either way `appNames` is a *partial* reading,
        /// and a partial app test that misses is indistinguishable from a
        /// complete one that misses, which is how a live product gets proved
        /// absent. The same rule `receiptPatternsFullyRead` carries for
        /// `pkgutil`, for the same reason.
        let appNamesFullyRead: Bool
        let paths: Set<String>
        /// The `pkgutil` patterns this cask declares, from either its `zap`
        /// or its `uninstall` stanza — the only anchor a cask with no `app`
        /// artifact has. Regular expressions as Homebrew writes them, stored
        /// verbatim: matching them against this machine's installed package
        /// ids is a separate decision, and nothing here interprets them.
        let receiptPatterns: Set<String>
        /// Whether every element of every `pkgutil` value this cask declares
        /// was read as a pattern. False when one was not a string, so the
        /// set above is a *partial* reading of what the cask declares.
        ///
        /// Tracked for `pkgutil` and for nothing else. A malformed element in
        /// a path array costs one path and leaves the rest of the offer
        /// usable, but an unread `pkgutil` element is a presence test that
        /// never ran — and a partial test that misses is indistinguishable
        /// from a complete one that misses, which is how a live product gets
        /// proved absent.
        let receiptPatternsFullyRead: Bool
    }

    /// The one derivation of "the same app bundle filename", used at every
    /// site that asks whether a declaration belongs to the app being queried.
    ///
    /// macOS's default filesystem is case-insensitive, so the casing
    /// `contentsOfDirectory` reports for a bundle is whatever its installer
    /// wrote, not a fact about the app: the mainline qBittorrent lands as
    /// `qbittorrent.app` while the cask declaring it spells the artifact
    /// `qBittorrent.app`. Exact comparison asks a question the filesystem
    /// does not answer, and answers it wrongly.
    ///
    /// Three call sites share this — forming the query group, Rule 3's
    /// foreign-path exclusion, and `foreignDeclarations` — and they must
    /// agree. A group formed case-insensitively while the exclusion stayed
    /// exact would count a cask as a stranger to its own app and subtract its
    /// paths back out to nothing.
    /// Internal rather than private: `RecoveredIdentities.recoverFromCasks`
    /// compares the same two things from the opposite side, deciding whether
    /// an installed bundle already accounts for a cask's declared app. Its
    /// own comment says it shares this comparison, and a second spelling
    /// would make that false silently — the query half answering correctly
    /// about an app while the recovery half mints a phantom absent row for it.
    static func nameKey(_ bundleName: String) -> String {
        bundleName.lowercased()
    }

    /// One cask's claim on one path, carrying enough identity to say who
    /// claimed it. `zapPaths(forAppBundleNamed:presence:)` answers with bare
    /// strings because its caller already knows the app; `FootprintAssembler` needs the
    /// declaring cask's name to label evidence and to name the foreign product
    /// keeping a shared root retained.
    ///
    /// `token` is carried because `appNames` is empty for a cask with no `app`
    /// artifact, and those are exactly the declarations a cross-app
    /// containment check must see.
    public struct CaskDeclaredPath: Sendable, Equatable {
        public let token: String
        public let path: String
        public let appNames: Set<String>

        public init(token: String, path: String, appNames: Set<String>) {
            self.token = token
            self.path = path
            self.appNames = appNames
        }
    }

    private let declarations: [Declaration]

    /// How many zap path strings across the cache contained a glob
    /// character (`*`, `?`, `[`) and were skipped rather than expanded.
    /// 1Password's own stanza uses globs (e.g. `Application Scripts/
    /// 2BUA8C4S2C.com.1password*`), so this is not a rare shape, and the
    /// evidence those paths would have carried is simply unavailable in
    /// this increment — this count is how a caller discloses that gap
    /// instead of silently under-reporting what a cask would free.
    public let skippedGlobPathCount: Int

    private init(declarations: [Declaration], skippedGlobPathCount: Int) {
        self.declarations = declarations
        self.skippedGlobPathCount = skippedGlobPathCount
    }
}

extension CaskIndex {

    /// Where Homebrew keeps its local cask metadata cache.
    public static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Homebrew/api/cask.jws.json", directoryHint: .notDirectory)
    }

    /// Every place Homebrew is known to keep the cask data, newest layout
    /// first.
    ///
    /// Homebrew 6.0 stopped writing `cask.jws.json` and moved the data into
    /// `api/internal/packages.<bottle-tag>.jws.json`. On such a machine the old
    /// file is gone and the whole cask evidence class goes with it. The bottle
    /// tag varies by machine and more than one file can be present, so the
    /// directory is enumerated rather than guessed at.
    ///
    /// The legacy path stays last, not deleted: a machine that has not run
    /// `brew update` since upgrading still has only the old file.
    public static var defaultCacheURLs: [URL] {
        let api = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Homebrew/api", directoryHint: .isDirectory)
        let internalDirectory = api.appending(path: "internal", directoryHint: .isDirectory)
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: internalDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("packages") }
            .filter { $0.pathExtension == "json" }
            // Deterministic order, so two machines with the same files agree
            // on which one was read.
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return packages + [defaultCacheURL]
    }

    /// The first of `defaultCacheURLs` that parses, or `nil` when none does.
    ///
    /// `nil` still means exactly what it meant before — this evidence source
    /// is unavailable, disclose it — rather than "Homebrew is missing". A
    /// present-but-unparseable file is the same fact to the caller.
    public static func loadFromDefaultCache() -> CaskIndex? {
        for url in defaultCacheURLs {
            if let index = load(from: url) { return index }
        }
        return nil
    }

    /// Builds the index from Homebrew's local cask cache at `url`, or
    /// returns `nil` if it cannot — a missing file, unreadable data, or a
    /// shape that does not match what this parses. Every one of those is a
    /// normal state, not an error: Homebrew not being installed is the
    /// common case on a fresh machine, and a source this reader cannot
    /// parse should contribute nothing rather than crash the scan that
    /// called it. `nil` is the same answer `EntitlementReader.applicationGroups`
    /// gives for a bundle it could not read — the source is unavailable, which
    /// is not the same fact as it having nothing to say.
    ///
    /// No network and no subprocess: this reads the file `brew` already wrote,
    /// never shelling out to `brew info`.
    ///
    /// The JSON is parsed twice because the file is JWS-wrapped: the top level
    /// is `{"payload": "<json>", "signatures": [...]}`, and the cask array is
    /// JSON encoded *as a string* inside `payload` rather than nested JSON.
    public static func load(from url: URL) -> CaskIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = envelope["payload"] as? String,
              let payloadData = payload.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: payloadData)
        else { return nil }

        // Two shapes, one reader — see `homebrew6PackagesCacheIsReadWithItsOwnShape`
        // for what changed and when. Each branch's only job is to yield
        // (token, appNames, rawPaths); everything after them is shared, so a
        // rule added to path handling cannot apply to one format and not the
        // other.
        let harvested: [(token: String, appNames: Set<String>, appNamesFullyRead: Bool,
     rawPaths: [String], receiptPatterns: Set<String>, receiptPatternsFullyRead: Bool)]
        if let casks = document as? [[String: Any]] {
            harvested = casks.map(harvestLegacy)
        } else if let payloadObject = document as? [String: Any],
                  let casks = payloadObject["casks"] as? [String: Any] {
            harvested = casks.compactMap { token, value in
                guard let cask = value as? [String: Any] else { return nil }
                return harvestHomebrew6(token: token, cask: cask)
            }
        } else {
            return nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var declarations: [Declaration] = []
        declarations.reserveCapacity(harvested.count)
        var skippedGlobPathCount = 0

        for entry in harvested {
            var paths: Set<String> = []
            for raw in entry.rawPaths {
                guard !containsGlobCharacter(raw) else {
                    skippedGlobPathCount += 1
                    continue
                }
                paths.insert(expandTilde(raw, home: home))
            }

            // A cask with no app artifact, no usable zap path and no receipt
            // pattern contributes nothing to either side of a future query —
            // skip storing it. A cask with only a receipt pattern IS stored:
            // it is exactly the anchor `receiptPatterns(forCaskToken:)` below
            // answers by token. So is one whose app artifacts could not be
            // read: dropping it would leave `declaresApp(forCaskToken:)`
            // answering "declares no app" from the token simply being missing,
            // which is the finding the flag exists to withhold.
            guard !entry.appNames.isEmpty || !paths.isEmpty || !entry.receiptPatterns.isEmpty
                    || !entry.appNamesFullyRead
            else { continue }
            declarations.append(Declaration(
                token: entry.token,
                appNames: entry.appNames,
                nameKeys: Set(entry.appNames.map(nameKey)),
                appNamesFullyRead: entry.appNamesFullyRead,
                paths: paths,
                receiptPatterns: entry.receiptPatterns,
                receiptPatternsFullyRead: entry.receiptPatternsFullyRead))
        }

        return CaskIndex(declarations: declarations, skippedGlobPathCount: skippedGlobPathCount)
    }

    /// The three `zap` keys that name filesystem paths. `launchctl`,
    /// `pkgutil`, `script`, `login_item` and `kext` are also real keys in
    /// the shipped cache — measured across all 4,646 casks carrying a zap
    /// stanza — and none of them is a path. Reading one would attribute a
    /// service label to an app as though it were a file.
    private static let zapPathKeys = ["trash", "delete", "rmdir"]

    /// The one `uninstall`/`zap` key naming installer receipt ids. Kept
    /// separate from `zapPathKeys` because it is not a path: reading it as
    /// one would attribute a package id to an app as though it were a file,
    /// the same mistake `zapPathKeys`' own doc comment guards against.
    private static let receiptPatternKey = "pkgutil"

    /// A nested source path inside the cask's own download (e.g.
    /// "Airfoil/Airfoil Satellite.app", measured in the real cache) still
    /// installs as just the trailing bundle name — take the basename so this
    /// matches what actually lands in /Applications, not the cask's internal
    /// layout.
    private static func bundleName(_ declared: String) -> String {
        (declared as NSString).lastPathComponent
    }

    private static func harvestLegacy(
        _ cask: [String: Any]
    ) -> (token: String, appNames: Set<String>, appNamesFullyRead: Bool, rawPaths: [String],
     receiptPatterns: Set<String>, receiptPatternsFullyRead: Bool) {
        var appNames: Set<String> = []
        var appNamesFullyRead = true
        var rawPaths: [String] = []
        var receiptPatterns: Set<String> = []
        var receiptPatternsFullyRead = true
        // Element by element, never `as? [[String: Any]]` on the whole array:
        // a wholesale cast fails entirely for one element that is not a dict,
        // dropping every artifact beside it — and it drops them silently, so
        // both completeness flags would stay `true` over a reading that read
        // nothing. Each element that cannot be read costs only itself, and
        // says so.
        let artifacts = cask["artifacts"]
        if artifacts != nil && artifacts as? [Any] == nil {
            appNamesFullyRead = false
            receiptPatternsFullyRead = false
        }
        for element in (artifacts as? [Any]) ?? [] {
            guard let artifact = element as? [String: Any] else {
                appNamesFullyRead = false
                receiptPatternsFullyRead = false
                continue
            }
            let apps = legacyAppNames(artifact["app"])
            appNames.formUnion(apps.names)
            appNamesFullyRead = appNamesFullyRead && apps.fullyRead
            // Paths and receipt patterns read in the same pass: a `zap`
            // stanza carries both kinds of key, and casting the array twice
            // to read one kind each time bought nothing.
            for stanza in legacyStanzas(artifact["zap"], fullyRead: &receiptPatternsFullyRead) {
                for key in zapPathKeys {
                    rawPaths.append(contentsOf: stringValues(stanza[key]))
                }
                let read = fullyReadStringValues(stanza[receiptPatternKey])
                receiptPatterns.formUnion(read.values)
                receiptPatternsFullyRead = receiptPatternsFullyRead && read.fullyRead
            }
            for stanza in legacyStanzas(artifact["uninstall"], fullyRead: &receiptPatternsFullyRead) {
                let read = fullyReadStringValues(stanza[receiptPatternKey])
                receiptPatterns.formUnion(read.values)
                receiptPatternsFullyRead = receiptPatternsFullyRead && read.fullyRead
            }
        }
        return ((cask["token"] as? String) ?? "", appNames, appNamesFullyRead, rawPaths,
                receiptPatterns, receiptPatternsFullyRead)
    }

    /// The installed bundle names one legacy `app` value declares, and whether
    /// this read all of them.
    ///
    /// The rename form is here too, in this cache's own spelling: an array
    /// whose second element is the artifact's options hash, `["CleanMyMac_5.app",
    /// {"target": "CleanMyMac.app"}]`. Measured against the published
    /// `formulae.brew.sh/api/cask.json`: 64 such entries across 61 casks — the
    /// same casks `homebrew6AppNames` reads a `:target` for — and every one of
    /// them exactly two elements, a string then a hash whose only key is
    /// `target`.
    ///
    /// The target is the name that lands in an Applications folder, and the
    /// string beside it is worse than nothing: it names the bundle inside the
    /// download, and some of those are a *different* cask's real installed
    /// name — `Thorium.app` is `alex313031-thorium`'s download and `thorium`'s
    /// install, `Android Studio.app` is `android-studio-preview@beta`'s
    /// download and `android-studio`'s install. Keeping it would offer one
    /// product's zap paths under another product's row.
    ///
    /// A `target` naming a path rather than a bare filename yields no name and
    /// reads short — 5 entries, `box-tools` installing four bundles under
    /// `~/Library/Application Support` and `ftdi-vcp-driver` an absolute path.
    /// A bundle placed there is not something an Applications-folder
    /// enumeration can find, so a name taken from it would miss for a reason
    /// that says nothing about whether the product is here.
    ///
    /// Anything else — no options hash, a hash with no usable `target`, more
    /// elements than this knows — reads short rather than guessing, exactly as
    /// the Homebrew 6.0 arm does.
    private static func legacyAppNames(_ value: Any?) -> (names: Set<String>, fullyRead: Bool) {
        guard let elements = value as? [Any],
              elements.contains(where: { $0 is [String: Any] })
        else {
            let read = fullyReadStringValues(value)
            return (Set(read.values.map(bundleName)), read.fullyRead)
        }
        guard elements.count == 2,
              let options = elements[1] as? [String: Any],
              let target = options["target"] as? String,
              !target.contains("/")
        else { return ([], false) }
        return ([target], true)
    }

    /// The stanzas of one legacy `zap` or `uninstall` value, clearing
    /// `fullyRead` for anything in it this could not read.
    ///
    /// An absent key leaves the flag alone: nothing was declared there, so
    /// nothing went unread. A value that is not an array, and any element of
    /// one that is not a stanza, takes the flag down — each of those hides a
    /// `pkgutil` pattern that would otherwise have joined the row's set, and a
    /// pattern set short by one is a presence test that did not fully run.
    private static func legacyStanzas(
        _ value: Any?, fullyRead: inout Bool
    ) -> [[String: Any]] {
        guard value != nil else { return [] }
        guard let elements = value as? [Any] else {
            fullyRead = false
            return []
        }
        var stanzas: [[String: Any]] = []
        for element in elements {
            guard let stanza = element as? [String: Any] else {
                fullyRead = false
                continue
            }
            stanzas.append(stanza)
        }
        return stanzas
    }

    /// Homebrew 6.0's `raw_artifacts`: an array of entries whose first element
    /// is a Ruby symbol rendered as `":app"` / `":zap"`, and whose `:zap`
    /// payload is a single dict rather than the old array of stanzas. The
    /// token is the caller's map key — nothing inside the cask carries it.
    ///
    /// Most entries are two-element pairs; 395 in the shipped cache carry a
    /// third element holding the artifact's options hash. Each arm below reads
    /// the shapes it knows and says so when it meets one it does not.
    private static func harvestHomebrew6(
        token: String, cask: [String: Any]
    ) -> (token: String, appNames: Set<String>, appNamesFullyRead: Bool, rawPaths: [String],
     receiptPatterns: Set<String>, receiptPatternsFullyRead: Bool) {
        var appNames: Set<String> = []
        var appNamesFullyRead = true
        var rawPaths: [String] = []
        var receiptPatterns: Set<String> = []
        var receiptPatternsFullyRead = true
        // Element by element, and every shape this cannot read says so — the
        // rule `harvestLegacy` above carries, on the arm that actually runs
        // today. Three shapes step wrong here: a `raw_artifacts` that is not
        // an array, an element of one that is not an array, and an element
        // whose first member is not an artifact kind. Each hides whatever
        // `:app` or `:pkgutil` it carried, so each clears both flags; passing
        // over one in silence leaves a completeness flag standing over a
        // reading that skipped something, which is a partial test claiming to
        // have run in full.
        let artifacts = cask["raw_artifacts"]
        if artifacts != nil && artifacts as? [Any] == nil {
            appNamesFullyRead = false
            receiptPatternsFullyRead = false
        }
        for element in (artifacts as? [Any]) ?? [] {
            guard let pair = element as? [Any], let kind = pair.first as? String else {
                appNamesFullyRead = false
                receiptPatternsFullyRead = false
                continue
            }
            switch kind {
            case ":app":
                let apps = homebrew6AppNames(pair)
                appNames.formUnion(apps.names)
                appNamesFullyRead = appNamesFullyRead && apps.fullyRead
            case ":zap":
                // A `:zap` this cannot read hides whatever `:pkgutil` it
                // carries, so it reads short rather than skipping quietly —
                // the same rule the legacy stanzas above follow.
                guard pair.count == 2, let stanza = pair[1] as? [String: Any] else {
                    receiptPatternsFullyRead = false
                    continue
                }
                for key in zapPathKeys {
                    rawPaths.append(contentsOf: stringValues(stanza[":" + key]))
                }
                let read = fullyReadStringValues(stanza[":" + receiptPatternKey])
                receiptPatterns.formUnion(read.values)
                receiptPatternsFullyRead = receiptPatternsFullyRead && read.fullyRead
            case ":uninstall":
                // Homebrew 6.0 gives `uninstall` a single dict, the same
                // shape it gives `zap`, rather than the array the legacy
                // cache uses.
                guard pair.count == 2, let stanza = pair[1] as? [String: Any] else {
                    receiptPatternsFullyRead = false
                    continue
                }
                let read = fullyReadStringValues(stanza[":" + receiptPatternKey])
                receiptPatterns.formUnion(read.values)
                receiptPatternsFullyRead = receiptPatternsFullyRead && read.fullyRead
            default:
                continue
            }
        }
        return (token, appNames, appNamesFullyRead, rawPaths, receiptPatterns,
                receiptPatternsFullyRead)
    }

    /// The installed bundle names one Homebrew 6.0 `:app` entry declares, and
    /// whether this read all of them.
    ///
    /// Two shapes occur in the shipped cache. A two-element entry names the
    /// bundle directly. A three-element one carries an options hash whose
    /// `:target` is the name the bundle is installed *as* — 64 entries across
    /// 61 casks, `cleanmymac` (`CleanMyMac_5.app` → `CleanMyMac.app`) and
    /// `bitcoin-core` (`Bitcoin-Qt.app` → `Bitcoin Core.app`) among them.
    ///
    /// The target is the only name worth having there, and the first element
    /// is worse than nothing: it is the name inside the cask's download, and
    /// seven of those source names are a *different* cask's real installed
    /// name — `Thorium.app` belongs to `thorium`, `Android Studio.app` to
    /// `android-studio`. Reading it as an app name would offer one product's
    /// zap paths under another product's row.
    ///
    /// A `:target` that names a path rather than a bare filename yields no
    /// name and reads short: 5 such entries today, `box-tools` installing four
    /// bundles under `~/Library/Application Support` and `ftdi-vcp-driver`
    /// writing an absolute path. A bundle placed there is not something an
    /// Applications-folder enumeration can find, so a name taken from it would
    /// miss for a reason that says nothing about whether the product is here.
    private static func homebrew6AppNames(_ pair: [Any]) -> (names: Set<String>, fullyRead: Bool) {
        switch pair.count {
        case 2:
            let read = fullyReadStringValues(pair[1])
            return (Set(read.values.map(bundleName)), read.fullyRead)
        case 3:
            guard let options = pair[2] as? [String: Any],
                  let target = options[":target"] as? String,
                  !target.contains("/")
            else { return ([], false) }
            return ([target], true)
        default:
            return ([], false)
        }
    }

    /// The zap paths safe to attribute to the installed bundle named
    /// `bundleName` (e.g. `"Google Chrome.app"`), narrowed by all three
    /// rules below. Returns an empty array if no cask's `app` artifact
    /// names this bundle, or if every path this app's own cask(s) declare
    /// gets refused by rule 3.
    public func zapPaths(
        forAppBundleNamed bundleName: String, presence: CaskPresence?
    ) -> [String] {
        zapDeclarations(forAppBundleNamed: bundleName, presence: presence).map(\.path)
    }

    /// Exactly `zapPaths(forAppBundleNamed:presence:)`, all three rules
    /// included, but carrying the declaring cask's token and app names. The two
    /// share one implementation deliberately: a second copy of the narrowing is
    /// the one way this type's three measured hazards could come back for
    /// only one of its callers.
    public func zapDeclarations(
        forAppBundleNamed bundleName: String, presence: CaskPresence?
    ) -> [CaskDeclaredPath] {
        // Rule 1 — app-anchored lookup only, never path to cask.
        //
        // Searching for "Application Support/Google" matches 46 casks, mostly
        // apps that install a native-messaging host into Chrome's directory.
        // A path-anchored search would attribute Chrome's 2.3 GB to 1Password.
        // The fix is structural: `group` is built by matching `bundleName`
        // against each cask's own `app` artifact, never by scanning zap paths
        // for a string. A cask that merely writes a file inside another app's
        // directory can never enter that app's query.
        let queryKey = Self.nameKey(bundleName)
        let group = declarations.filter { $0.nameKeys.contains(queryKey) }
        return narrow(
            group: group, excluding: { $0.nameKeys.contains(queryKey) }, presence: presence)
    }

    /// The token-anchored twin of `zapDeclarations(forAppBundleNamed:presence:)`,
    /// for a cask with no `app` artifact — reachable only because
    /// `RecoveredIdentities` anchored it on a receipt. Rules 2 and 3 are the
    /// same code, not a second copy: an anchor decides which declarations
    /// form the group, never how tightly the group is narrowed.
    ///
    /// Rule 1 holds here too, in the same structural way. The group is built
    /// by matching the cask's own token — the installer's own name for
    /// itself, handed down from a `pkgutil` receipt — never by scanning zap
    /// paths for a string, so a cask that merely writes into another
    /// product's directory can no more enter this query than an app-anchored
    /// one.
    public func zapDeclarations(
        forCaskToken token: String, presence: CaskPresence?
    ) -> [CaskDeclaredPath] {
        // `""` is not a cask — see `Declaration.token`.
        guard !token.isEmpty else { return [] }
        let group = declarations.filter { $0.token == token }
        return narrow(group: group, excluding: { $0.token == token }, presence: presence)
    }

    /// Rules 2 and 3, applied to whichever declarations an anchor selected.
    /// `isOwn` decides which declarations count as the queried product's own
    /// and are therefore not strangers for Rule 3's purposes.
    ///
    /// Shared by both anchors deliberately, and for the same reason
    /// `zapPaths` and `zapDeclarations` share one implementation: a second
    /// copy of this narrowing is the one way this type's measured hazards
    /// could come back for only one of its callers. A cask reachable only by
    /// token must not be held to a weaker standard than one reachable by app.
    private func narrow(
        group: [Declaration],
        excluding isOwn: (Declaration) -> Bool,
        presence: CaskPresence?
    ) -> [CaskDeclaredPath] {
        guard !group.isEmpty else { return [] }

        let ownPaths = group.reduce(into: Set<String>()) { $0.formUnion($1.paths) }

        // Rule 2 — prefer the most specific declaration; refuse a cask's
        // own bare ancestor.
        //
        // Chrome's cask declares both "Application Support/Google/Chrome" and
        // the bare "Application Support/Google"; honouring the second removes
        // every other Google product's data. Edge does the same with
        // "Microsoft". A path is refused only when another path the same cask
        // — or one of its own variants, such as `1password@beta` — declares
        // sits strictly beneath it, proving it is not this cask's most specific
        // claim.
        let survivingRule2 = ownPaths.filter { candidate in
            !ownPaths.contains { other in
                other != candidate && other.hasPrefix(candidate + "/")
            }
        }

        // Rule 3 — refuse a declared path that another, unrelated cask
        // independently claims.
        //
        // "Application Support/Microsoft" holds Word and Excel data and is
        // declared by both `microsoft-edge` and the separate `microsoft-word`
        // cask. Two unrelated casks naming the same directory is the signal it
        // is a shared vendor root, even where Rule 2 has nothing of Edge's own
        // to prefer over it.
        //
        // Deliberately exact-path equality, not "ancestor of anything another
        // cask declares beneath it": 1Password's nested file under Chrome's
        // directory must not strip Chrome's claim to it, and exact-duplicate
        // matching is what separates the two cases.
        //
        // This therefore misses a path only one cask declares that is still an
        // ancestor of another app's deeper declaration. That gap needs every
        // app's declarations at once, so it belongs to the assembler. Do not
        // widen this check to ancestor-of-anything.
        //
        // Rule 3 is narrowed to this machine. A catalogue entry is evidence of
        // a shared vendor root only if the product sharing it is actually
        // here: `Application Support/Microsoft/EdgeUpdater` is declared by
        // four Edge variants, and on a machine with one of them installed the
        // other three are not co-owners, they are absent. `presence == nil`
        // keeps the catalogue-wide answer for callers that have no machine
        // context to offer.
        let foreignPaths = declarations.reduce(into: Set<String>()) { result, declaration in
            guard !isOwn(declaration) else { return }
            if let presence, presence.isProvablyAbsent(declaration.token) { return }
            result.formUnion(declaration.paths)
        }

        return survivingRule2.subtracting(foreignPaths).sorted().map { path in
            // The declaring cask is looked up within `group` only — the
            // casks the anchor already selected. Searching all declarations
            // for the path would be the reverse, path-to-cask lookup Rule 1
            // exists to forbid.
            let owner = group.first { $0.paths.contains(path) }
            return CaskDeclaredPath(
                token: owner?.token ?? "", path: path, appNames: owner?.appNames ?? [])
        }
    }

    /// Every path declared by a cask that does **not** install `bundleName`
    /// and that sits strictly below `path`.
    ///
    /// Raw material for a check `CaskIndex` cannot make itself. Rule 3 refuses
    /// only paths two casks declare identically, so a path one cask declares
    /// that is an ancestor of another app's deeper declaration is invisible to
    /// a single-app query.
    ///
    /// This reports containment facts and takes no view on them. Which
    /// descendants mean a shared root, and which mean an integration that
    /// should die with its host, is `FootprintAssembler`'s judgment.
    /// Deliberately not filtered to installed apps: the declarations that
    /// matter most come from casks with no `app` artifact. `presence` drops
    /// only casks it can *prove* absent, which is a strictly narrower thing —
    /// a cask with no positive test is never provable and so still counts,
    /// exactly as it does today. `nil` keeps the catalogue-wide answer.
    public func foreignDeclarations(
        below path: String, ofAppBundleNamed bundleName: String, presence: CaskPresence?
    ) -> [CaskDeclaredPath] {
        let queryKey = Self.nameKey(bundleName)
        return foreignDeclarations(
            below: path, excluding: { $0.nameKeys.contains(queryKey) }, presence: presence)
    }

    /// The token-anchored twin of
    /// `foreignDeclarations(below:ofAppBundleNamed:presence:)`, for a cask
    /// with no `app` artifact — the same anchor `zapDeclarations(forCaskToken:presence:)`
    /// uses, so the caller that queried an identity by token asks about
    /// strangers by token too. Asking by app bundle name instead excludes
    /// declarations carrying an app name such a cask does not have, which
    /// excludes nothing, and the cask's own deeper declaration comes back as
    /// a stranger's claim on its own ancestor.
    public func foreignDeclarations(
        below path: String, ofCaskToken token: String, presence: CaskPresence?
    ) -> [CaskDeclaredPath] {
        // `""` is not a cask — see `Declaration.token` — so it names nothing
        // to exclude and every declaration below `path` stays foreign. That
        // is the retaining direction; excluding on it would let one untokened
        // entry's declarations vouch for every other untokened entry's.
        foreignDeclarations(
            below: path, excluding: { !token.isEmpty && $0.token == token }, presence: presence)
    }

    /// The containment scan itself, over whichever declarations an anchor
    /// counts as the queried product's own. Shared by both anchors for the
    /// same reason `narrow` is: a second copy is how one anchor ends up held
    /// to a different standard than the other.
    private func foreignDeclarations(
        below path: String, excluding isOwn: (Declaration) -> Bool, presence: CaskPresence?
    ) -> [CaskDeclaredPath] {
        // Both sides are normalized through `Candidate.normalizedPathKey(for:)`
        // before comparison, and the returned `path` is the normalized form.
        //
        // A cask zap path is author-written text with only `~` expanded: a
        // trailing slash, a doubled `//` or a `./` segment all occur, and any
        // makes a raw `hasPrefix` miss. A miss fails toward release — the
        // caller concludes nothing else declares anything beneath the path and
        // offers a shared root. `zapDeclarations` stays unnormalized because it
        // reports what a cask literally declared.
        let prefix = Candidate.normalizedPathKey(for: URL(fileURLWithPath: path)) + "/"
        var result: [CaskDeclaredPath] = []
        for declaration in declarations where !isOwn(declaration) {
            if let presence, presence.isProvablyAbsent(declaration.token) { continue }
            for declared in declaration.paths {
                let key = Candidate.normalizedPathKey(for: URL(fileURLWithPath: declared))
                guard key.hasPrefix(prefix) else { continue }
                result.append(CaskDeclaredPath(
                    token: declaration.token, path: key, appNames: declaration.appNames))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Every `(token, appName)` pair the casks declare through an `app`
    /// artifact — the reverse of every other query here, which starts from an
    /// app name the caller already has. `RecoveredIdentities` needs to discover
    /// an app name, and the token naming it, for an app no longer installed.
    /// Hands back only `token` and `appName`; the underlying paths stay
    /// reachable through the app-anchored queries.
    ///
    /// A cask with no `app` artifact contributes nothing, since nothing can
    /// name it as the answer to an app-shaped question.
    public func declaredApps() -> [(token: String, appName: String)] {
        declarations.flatMap { declaration in
            declaration.appNames.map { (declaration.token, $0) }
        }
    }

    /// Whether the cask named `token` declares any `app` artifact. `false` is
    /// what makes a cask reachable only by token — the receipt-anchored
    /// case the assembler branches on.
    ///
    /// `nil` when no declaration under this token names an app **and** at
    /// least one of them could not be read in full. "Declares no app" is a
    /// finding about the cask; "could not read what it declares" is a fact
    /// about this parse, and the two send an identity down different anchors.
    /// Answering `false` for the second would put a cask that does declare an
    /// app onto the token anchor, which shrinks the caller's own-path union
    /// and releases a path a sibling variant still lives under. So the
    /// unreadable case withholds and the caller keeps its app-shaped anchor.
    ///
    /// **Answered from every declaration carrying the token, not one of
    /// them.** The legacy cache is an array with no uniqueness rule, so two
    /// entries can wear the same token; reading whichever came first would
    /// make the answer depend on cache order rather than on the cask. Any
    /// one of them declaring an app is enough — an app was declared under
    /// this token — and it settles the answer whatever the others could not
    /// be read.
    public func declaresApp(forCaskToken token: String) -> Bool? {
        // `""` is not a cask — see `Declaration.token`.
        guard !token.isEmpty else { return false }
        let carrying = declarations.filter { $0.token == token }
        if carrying.contains(where: { !$0.appNames.isEmpty }) { return true }
        if carrying.contains(where: { !$0.appNamesFullyRead }) { return nil }
        return false
    }

    /// Every token the index holds, including the casks that declare no
    /// `app` artifact — exactly the ones whose presence is hardest to
    /// establish and which an app-shaped lookup can never reach.
    public func allTokens() -> [String] {
        // `""` is not a cask, so it never becomes a recovered identity —
        // see `Declaration.token`.
        declarations.map(\.token).filter { !$0.isEmpty }
    }

    /// Every `pkgutil` receipt pattern the cask named `token` declares.
    /// Empty for an unknown token and for a cask that declares none —
    /// the two are deliberately indistinguishable here, because both mean
    /// "this index cannot anchor that token on a receipt."
    ///
    /// **The union across every declaration carrying the token, not one of
    /// them**, for the reason `declaresApp(forCaskToken:)` states: two
    /// entries can wear the same token, and reading whichever came first
    /// would answer from cache order. The union is also the safe direction
    /// — a pattern left out is a receipt this machine is never asked about.
    public func receiptPatterns(forCaskToken token: String) -> Set<String> {
        // `""` is not a cask — see `Declaration.token`.
        guard !token.isEmpty else { return [] }
        return declarations.reduce(into: Set<String>()) { result, declaration in
            guard declaration.token == token else { return }
            result.formUnion(declaration.receiptPatterns)
        }
    }

    /// One row per declaration, carrying everything `CaskPresence` needs.
    ///
    /// Exists so `resolve` reads the catalogue **once**. Asking a
    /// per-token accessor inside a loop over every token is a linear scan
    /// per token across 7,713 declarations — 59 million comparisons on the
    /// shipped cache, for an answer that does not depend on the identity
    /// being swept. Same reasoning as the shelf and messaging-host
    /// snapshots.
    public func presenceInputs()
        -> [(token: String, appNameKeys: Set<String>, appNameKeysFullyRead: Bool,
             receiptPatterns: Set<String>, receiptPatternsFullyRead: Bool)] {
        // `""` is not a cask, so nothing about it can be proved absent —
        // see `Declaration.token`.
        declarations.filter { !$0.token.isEmpty }
            .map { ($0.token, $0.nameKeys, $0.appNamesFullyRead, $0.receiptPatterns,
                    $0.receiptPatternsFullyRead) }
    }
}

/// Whether each cask in the catalogue is on **this machine**, so Rule 3 can
/// ask about a rival's presence rather than about its mere membership in a
/// catalogue of 7,713 casks nearly none of which are installed.
///
/// Three positive signals, and one rule that matters more than all of them:
/// **no signal available means present.** "Not detected" and "not installed"
/// are indistinguishable for a cask with no `app` artifact and no receipt
/// pattern — measured, 2,979 of 7,713 — and reading the first as the second
/// releases another product's data. This is the same failure shape as
/// `PathGuard.isRootOwned` reporting an absent path as root-owned: failing
/// closed was right, being indistinguishable was the bug. Here the ambiguity
/// is unavoidable, so the fallback is the safe one and the caller is never
/// told a guess is a finding.
public struct CaskPresence: Sendable {
    /// Tokens for which a two-sided test actually ran and failed. A token
    /// absent from this set — including one this type never examined,
    /// because the catalogue does not contain it or could not be read — is
    /// not provably absent. The set holds proofs, never assumptions.
    private let provablyAbsent: Set<String>

    private init(provablyAbsent: Set<String>) {
        self.provablyAbsent = provablyAbsent
    }

    /// True only when a positive test for `token` exists **and** it failed.
    /// False for a token that passed a test, and false for a token no test
    /// could reach — including one the catalogue never mentions, and every
    /// token when the catalogue itself failed to load.
    public func isProvablyAbsent(_ token: String) -> Bool {
        provablyAbsent.contains(token)
    }

    /// All three signals share one shape. `nil` means the source could not be
    /// read, so the signal is unusable — it never sets `hadUsableSignal` and
    /// never matches. A non-nil empty set means the source was read and is
    /// empty, which for the two two-sided signals is itself a finding: it
    /// proves a cask relying only on that signal absent. `caskroomTokens` is
    /// positive-only and proves absence for nobody either way. `nil` is never
    /// coalesced to empty, which would promote "could not check" into
    /// "checked, and it failed".
    ///
    /// `installedAppFilenames` are `InstalledApps.discoveredBundleFilenames`,
    /// the walk's own output, and **not** names derived from `byID` — that map
    /// drops a bundle whose `Info.plist` would not parse while the bundle sits
    /// there, and a cask matches on a filename the walk knows regardless. Keyed
    /// through `nameKey` here, not by the caller.
    ///
    /// The two `FullyRead` flags carry the *partial* case, which `nil` cannot
    /// express: the source answered, but short by an unknown amount — a listing
    /// abandoned on a stalled mount, or a receipt plist that would not parse
    /// (`ReceiptStore.read(in:)` reports the latter). The values are kept
    /// rather than discarded, because a hit in a short set is still proof of
    /// presence; only a *miss* against one stops being a finding. Discarding
    /// them instead would let the other arm's miss prove absence unopposed.
    /// Same rule `appNameKeysFullyRead` and `receiptPatternsFullyRead` carry one
    /// level up.
    public static func resolve(
        index: CaskIndex,
        installedAppFilenames: Set<String>?,
        installedAppFilenamesFullyRead: Bool,
        receiptPackageIDs: Set<String>?,
        receiptPackageIDsFullyRead: Bool,
        caskroomTokens: Set<String>?
    ) -> CaskPresence {
        let installedKeys = installedAppFilenames.map { Set($0.map(CaskIndex.nameKey)) }
        let rows = index.presenceInputs()

        // Every declared receipt pattern compiled once for the whole
        // catalogue rather than once per row that declares it. This sweeps
        // ~7,713 declarations, and a cask's variants declare the same
        // pattern, so compiling inside the row loop below paid
        // `NSRegularExpression`'s parse again for every repeat.
        //
        // Built over every pattern every row declares, so a pattern absent
        // from the map is one that was tried and would not compile — there
        // is no "never attempted" third state for the lookup below to
        // mistake for it. Skipped entirely when there are no receipt ids to
        // match against, since then no pattern is ever run.
        //
        // Anchored at compile time, not by comparing match range to the
        // whole string: `firstMatch` finds the leftmost alternative that
        // matches anywhere, so `a|ab` against "ab" can match just "a" and
        // report a range shorter than the string even though the pattern as
        // a whole is satisfiable end-to-end. Wrapping in `^(?:...)$` makes
        // the anchors part of what has to match, which alternation and
        // laziness cannot route around. The non-capturing group keeps the
        // anchors binding around the whole pattern rather than just its
        // first alternative.
        var compiledPatterns: [String: NSRegularExpression] = [:]
        if receiptPackageIDs != nil {
            for row in rows {
                for pattern in row.receiptPatterns where compiledPatterns[pattern] == nil {
                    guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$")
                    else { continue }
                    compiledPatterns[pattern] = regex
                }
            }
        }

        var provablyAbsent: Set<String> = []
        for row in rows {
            let token = row.token
            var hadUsableSignal = false

            if let installedKeys, !row.appNameKeys.isEmpty {
                // A match is proof of presence whichever name produced it, so
                // it stands even when the rest of the row's app artifacts went
                // unread, and whatever the enumeration missed. A miss is only a
                // finding when every app this cask declares became a name to
                // compare AND the enumeration read every place it looks —
                // otherwise the test that missed is a partial one, and a
                // partial test that misses is indistinguishable from a complete
                // one that misses. Same rule the receipt patterns below carry,
                // for the same reason.
                if !row.appNameKeys.isDisjoint(with: installedKeys) {
                    continue
                }
                if row.appNameKeysFullyRead && installedAppFilenamesFullyRead {
                    hadUsableSignal = true
                }
            }

            // An unreadable receipt database is not a usable signal for a
            // `:pkgutil` pattern, the same way an unreadable Caskroom is not
            // a usable signal below: absence of evidence is not evidence of
            // absence, and treating it as one would mark every pkgutil-only
            // cask provably absent on a machine that simply couldn't read
            // its receipts.
            if let receiptPackageIDs, !row.receiptPatterns.isEmpty {
                var matched = false
                // Every declared pattern has to be both READ and runnable
                // before a miss counts as a finding. An element the parse
                // could not read as a string never became a pattern, and one
                // that will not compile never ran; either way the patterns
                // that did run are a partial test, and a partial test that
                // fails is indistinguishable from a complete test that fails
                // — the same confusion between "found nothing" and "could
                // not look" the `nil` signals above exist to prevent. Both
                // are tracked in one flag rather than skipping the whole row,
                // because the same row may carry a usable app signal that
                // stays valid.
                // Both sides of the comparison have to have been read whole
                // before a miss counts. `receiptPatternsFullyRead` covers the
                // patterns; `receiptPackageIDsFullyRead` covers the ids they
                // are run against, which `ReceiptStore` leaves short when a
                // plist in a readable database will not parse. Either being
                // short makes this a partial test, and a partial test that
                // misses is indistinguishable from a complete one that misses.
                var everyPatternUsable = row.receiptPatternsFullyRead
                    && receiptPackageIDsFullyRead
                for pattern in row.receiptPatterns {
                    // Missing from the map means this pattern would not
                    // compile — see where the map is built. It never ran, so
                    // whatever the rest of them say is a partial test.
                    guard let regex = compiledPatterns[pattern] else {
                        everyPatternUsable = false
                        continue
                    }
                    if receiptPackageIDs.contains(where: { id in
                        let range = NSRange(id.startIndex..<id.endIndex, in: id)
                        return regex.firstMatch(in: id, options: [], range: range) != nil
                    }) {
                        matched = true
                        break
                    }
                }
                // A match is proof of presence whichever pattern produced
                // it, so it stands even though the loop stopped early.
                if matched { continue }
                if everyPatternUsable { hadUsableSignal = true }
            }

            // The Caskroom is a POSITIVE signal only. It is Homebrew's
            // record of what it installed, so membership proves presence —
            // but a miss proves nothing, because a cask's payload can
            // arrive by npm, curl or a downloaded installer and never be
            // recorded here at all. Counting a miss as proof of absence
            // would release another product's data on the strength of it
            // not having been installed by Homebrew, which is the one
            // direction this type exists to prevent. So this never sets
            // `hadUsableSignal`.
            if let caskroomTokens, caskroomTokens.contains(token) {
                continue
            }

            if hadUsableSignal { provablyAbsent.insert(token) }
        }
        return CaskPresence(provablyAbsent: provablyAbsent)
    }
}

/// Reads a JSON value that Homebrew's cask schema allows to be either a
/// single string or an array of strings — `zap`'s `trash`/`delete`/`rmdir`
/// keys, and nothing else now — returning `[]` for anything else: absent,
/// wrong type, or an array whose entries are not all strings. A malformed
/// entry contributes nothing rather than crashing the whole parse; entries
/// within a mixed array that *are* strings are still kept rather than
/// discarding the array wholesale for one bad element.
///
/// That leniency is right for a path, which is an offer, and wrong for the
/// values a presence test is run from, whose caller has to know whether it
/// read all of them — see `fullyReadStringValues(_:)`.
private func stringValues(_ value: Any?) -> [String] {
    if let array = value as? [Any] {
        return array.compactMap { $0 as? String }
    }
    if let single = value as? String {
        return [single]
    }
    return []
}

/// `stringValues(_:)` for the two values that feed a presence *test* — a
/// `pkgutil` pattern set and an `app` artifact — reporting whether it read the
/// whole of what was declared.
///
/// A path key can afford to drop a malformed element: the caller loses one
/// path off an offer and the rest stays useful. A presence test read only in
/// part is a test that did not fully run — which, when it misses, looks
/// exactly like a complete test that missed, and proves a live product absent.
/// So the two facts travel together and the caller decides, rather than being
/// handed a short set it cannot tell from a whole one.
///
/// An absent key reads as complete: nothing was declared, so nothing went
/// unread. A present value that is neither a string nor an array is not
/// complete — something was declared and this cannot say what.
private func fullyReadStringValues(_ value: Any?) -> (values: [String], fullyRead: Bool) {
    if value == nil { return ([], true) }
    if let array = value as? [Any] {
        let strings = array.compactMap { $0 as? String }
        return (strings, strings.count == array.count)
    }
    if let single = value as? String {
        return ([single], true)
    }
    return ([], false)
}

/// True if `path` contains a shell glob metacharacter. Homebrew's cask
/// schema allows globs in zap paths — 1Password's own stanza uses one
/// (`Application Scripts/2BUA8C4S2C.com.1password*`) — and expanding a
/// glob against the real filesystem is out of scope for this increment;
/// see `CaskIndex.skippedGlobPathCount`.
private func containsGlobCharacter(_ path: String) -> Bool {
    path.contains("*") || path.contains("?") || path.contains("[")
}

/// Expands a leading `~` to `home`. Cask zap paths are written relative to
/// the *installing* user's home, and `home` must be the real home
/// directory for the user running this process, not a hardcoded path — a
/// wrong home silently produces paths that exist nowhere, which reads as
/// "this cask frees no space" rather than as the error it actually is.
private func expandTilde(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
}
