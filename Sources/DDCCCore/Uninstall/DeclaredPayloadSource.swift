import Foundation

/// Payload an application installs that no enumerating source attributes to
/// it, declared from a curated table.
///
/// Two shapes qualify. Some payload lives outside `~/Library` and outside the
/// app's own bundle, where no source looks at all -- Epic's engine under
/// `/Users/Shared`, Unity's editors under `/Applications/Unity`. The rest sits
/// inside an allowlisted shelf but is named after the product rather than the
/// bundle id, so `ShelfSource`'s exact-id match walks past it:
/// `~/Library/Caches/UnityHub` is never `~/Library/Caches/com.unity3d.unityhub`.
///
/// Every other `FootprintSource` enumerates: it lists what a shelf or a
/// container directory actually holds and attributes the entries it finds. It
/// can therefore never invent a path. This one declares, which is weaker
/// evidence, and the difference shapes the whole design:
///
/// - Each entry names an **exact directory**, never a parent to be searched.
///   `/Users/Shared` is shared by every account on the machine; only a
///   vendor-specific directory inside it is ever named.
/// - A declared path that is not on disk emits nothing, so a table entry for
///   an app that installed elsewhere adds a phantom to no footprint.
/// - An identity absent from the table gets nothing at all. The table is not a
///   general escape from the allowlist; it is a list of apps whose payload
///   location has been measured.
///
/// Why it exists: Epic Games Launcher keeps 43 GB of engine under
/// `/Users/Shared/Epic Games` and a 21 GB download cache under
/// `/Users/Shared/UnrealEngine`. Neither is a bundle, neither sits under a
/// search root, and Epic ships a `.dmg`, so no receipt or cask names them
/// either. Uninstalling the launcher reported ~1.2 GB and silently left 45 GB
/// behind, with nothing in the interface to say so.
public struct DeclaredPayloadSource: FootprintSource {

    /// Measured on this project's development machine, 2026-08-29, against a
    /// reinstalled UE 5.8. Both are Epic's own directories, not shared ones:
    /// `Epic Games` holds the engine (43 GB), `UnrealEngine` holds the
    /// launcher's vault cache of store downloads (1.6 GB at the time).
    ///
    /// The engine directory is deliberately named at its root rather than per
    /// version. A machine can hold several engine versions and removing the
    /// launcher orphans all of them equally.
    public static let shippedTable: [String: [String]] = [
        "com.epicgames.EpicGamesLauncher": [
            "/Users/Shared/Epic Games",
            "/Users/Shared/UnrealEngine",
            // The per-user side, none of which went with an uninstall before.
            // Logs and LaunchAgents are outside the eight allowlisted shelves
            // entirely; `Preferences/Unreal Engine` is inside one but named
            // after the product rather than the bundle id, which is the same
            // miss as Unity's `Caches/UnityHub`.
            //
            // Measured with the launcher installed and no engine: 103 MB of
            // launcher data, 261 MB of logs. The first grows to 1.6 GB once an
            // engine is installed, since the derived data cache and Zen store
            // live under it.
            "~/Library/Application Support/Epic",
            "~/Library/Application Support/Unreal Engine",
            "~/Library/Logs/Unreal Engine",
            "~/Library/Preferences/Unreal Engine",
            // Declared so it goes WITH the uninstall. Left behind it asks
            // macOS to launch a deleted application at every login; the
            // dead-artifact sweep is the backstop for one that outlived its
            // app, and this is how it does not outlive it in the first place.
            "~/Library/LaunchAgents/com.epicgames.launcher.plist",
        ],

        // Unity Hub installs every editor into a folder it owns, so the
        // editors go with the Hub that installed them rather than being left
        // as orphans no app claims. 17 GB for one editor, measured.
        //
        // The rest is here for a different reason than Epic's: these paths are
        // inside allowlisted shelves and an enumerating source walks right past
        // them, because ShelfSource matches an exact bundle id and Unity names
        // its directories after the product -- `Caches/UnityHub`, never
        // `Caches/com.unity3d.unityhub`. Measured before this: uninstalling the
        // Hub reported 488 MB and left 2.5 GB behind.
        //
        // `~/Library/Unity` itself is deliberately absent. It holds `licenses`,
        // the machine's Unity activation, so only the asset cache inside it is
        // named.
        "com.unity3d.unityhub": [
            "/Applications/Unity",
            "~/Library/Unity/Asset Store-5.x",
            "~/Library/Application Support/UnityHub",
            "~/Library/Caches/UnityHub",
            "~/Library/Caches/Unity",
            "~/Library/Caches/com.unity3d.UnityEditor",
        ],

        // The SDK is installed BY Studio, into a directory Studio owns, and is
        // the same case as Unity Hub's editors: 1.8 GB that no app claimed
        // before this line, sitting under a path an enumerating source walks
        // past because it is named after the platform rather than the bundle
        // id. Measured on a fresh install carrying one API level -- 1.2 GB of
        // that is the emulator alone.
        //
        // It is worth saying what this decides, because the SDK is not only
        // Studio's: Flutter, React Native and a plain Gradle build all reach
        // it through ANDROID_HOME. Removing Studio takes the SDK those would
        // have used. That is the intended behaviour here rather than an
        // oversight -- Studio is what installed it -- but it is a choice, and
        // the Caches view is where a machine without Studio still gets at the
        // stale parts of it.
        //
        // The other three are version-stamped, which is what the trailing `*`
        // is for. Their parent is the vendor rather than the product --
        // `~/Library/Caches/Google` holds Chrome's cache beside Studio's -- so
        // naming the parent would take the browser's cache with the IDE, and
        // naming `AndroidStudio2026.1.4` exactly would be wrong at the next
        // upgrade. Measured: 236 MB of cache, 1 MB of settings, and logs.
        // `~/.android` is deliberately absent, on the same argument as Unity's
        // licences. It holds `adbkey`, this machine's ADB identity: remove it
        // and every physical device the user has ever authorised has to
        // authorise again, from a dialog on the phone. `avd` sits beside it
        // and holds the apps installed inside each emulator. Neither is
        // Studio's to take, and both are reachable from the Caches view --
        // the virtual devices as tier 3, which is where that choice belongs.
        "com.google.android.studio": [
            "~/Library/Android/sdk",
            "~/Library/Caches/Google/AndroidStudio*",
            "~/Library/Application Support/Google/AndroidStudio*",
            "~/Library/Logs/Google/AndroidStudio*",
        ],

        // `~/Library/Application Support/Godot` itself is deliberately absent.
        // It holds `app_userdata`, which is save data written BY Godot games
        // and the one thing under there that is not Godot's to remove -- the
        // Caches view already denylists it. Only the engine's own downloads
        // are named.
        "org.godotengine.godot": [
            "~/Library/Application Support/Godot/export_templates",
            "~/Library/Application Support/Godot/shader_cache",
            "~/Library/Caches/Godot",
        ],
    ]

    private let table: [String: [String]]

    public init(table: [String: [String]] = DeclaredPayloadSource.shippedTable) {
        self.table = table
    }

    public func evidence(for identity: BundleIdentity, in env: ScanEnvironment) -> [EvidenceItem] {
        // Refused at the top, as every source in this project does, so a
        // curated table cannot become the one door Apple's namespace fits
        // through.
        guard isAppleOwned(identity.bundleID) == false else { return [] }

        return (table[identity.bundleID] ?? []).flatMap { declared in
            Self.matches(for: declared).map { path in
                EvidenceItem(
                    path: Candidate.normalizedPathKey(
                        for: URL(fileURLWithPath: path, isDirectory: true)),
                    source: .declaredPayload,
                    claimedBy: identity.bundleID)
            }
        }
    }

    /// The concrete paths one declared entry names, and only those that exist.
    ///
    /// A trailing `*` on the final component matches the direct children of
    /// its parent whose names begin with the prefix. It exists because an IDE
    /// stamps its support directories with the release —
    /// `AndroidStudio2026.1.4`, `IntelliJIdea2026.1` — so an exact path is
    /// wrong again at the next upgrade, while the parent belongs to the vendor
    /// rather than the product: `~/Library/Caches/Google` holds Chrome's cache
    /// beside Android Studio's.
    ///
    /// A star with nothing before it expands to nothing rather than to
    /// everything. `.../Google/*` is the declaration of a shared parent with a
    /// different spelling, and it is the one this mechanism exists to avoid —
    /// note that the forbidden-parent guard would not catch it, since it
    /// forbids `~/Library/Caches` and not `~/Library/Caches/Google`.
    ///
    /// Direct children only. Recursing would attribute every file inside a
    /// matched directory separately, where the assembler wants the root.
    private static func matches(for declared: String) -> [String] {
        // Expanded through ScanProfile.expand, the one place in this project
        // that decides what `~` means, rather than a second spelling that
        // could disagree with it.
        let expanded = ScanProfile.expand(declared)
        guard expanded.hasSuffix("*") else {
            return FileManager.default.fileExists(atPath: expanded) ? [expanded] : []
        }

        let stem = String(expanded.dropLast())
        // The separator is what makes the prefix empty, and NSString would
        // hide it: lastPathComponent of ".../Google/" is "Google", which would
        // silently turn a bare wildcard into a match on the parent itself.
        guard stem.hasSuffix("/") == false else { return [] }

        let parent = (stem as NSString).deletingLastPathComponent
        let prefix = (stem as NSString).lastPathComponent
        guard prefix.isEmpty == false else { return [] }

        let children = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        return children.filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { (parent as NSString).appendingPathComponent($0) }
    }
}
