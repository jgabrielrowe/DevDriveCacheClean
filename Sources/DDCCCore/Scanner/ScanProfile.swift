import Foundation

public struct ScanProfile: Sendable {
    public let category: CleanCategory
    public let patterns: [Pattern]

    public init(category: CleanCategory, patterns: [Pattern]) {
        self.category = category
        self.patterns = patterns
    }

    public struct Pattern: Sendable {
        public let kind: Kind
        public let tier: RemovalTier
        public let removability: Removability

        public init(kind: Kind, tier: RemovalTier, removability: Removability = .removable) {
            self.kind = kind
            self.tier = tier
            self.removability = removability
        }

        public enum Kind: Sendable {
            /// Match a directory by name during traversal, optionally gated on a marker file.
            case directoryName(String, marker: Marker?)
            /// A single fixed path. `~` is expanded against the current user's home.
            case absolutePath(String)
            /// Each subdirectory of `parentPath` becomes its own candidate.
            case subdirectories(parentPath: String, minSize: Int64)
            /// Each installed toolchain version under `parentPath` that is
            /// not still in use — see `ToolchainVersions` for what "in use"
            /// means and why each retention is there. `pointerPath` is the
            /// manager's record of which version it considers current
            /// (`~/.nvm/alias/default`, `~/.pyenv/version`); `aliasDirectory`
            /// is where an alias chain is followed, and is `nil` for managers
            /// whose pointer names a version directly.
            case toolchainVersions(
                parentPath: String, pointerPath: String?, aliasDirectory: String?, minSize: Int64)
            /// Each version directory under `parentPath` for which no engine
            /// of that version is installed. The engine says where installed
            /// versions are read from -- see `EngineVersions`, which also
            /// explains why an unparseable name and an empty install list both
            /// offer nothing.
            case engineVersions(parentPath: String, engine: EngineVersions.Engine, minSize: Int64)
            /// A fixed `subpath` inside each subdirectory of `parentPath`.
            /// Reaches `~/Library/Containers/*/Data/Library/Caches` without
            /// touching the containers themselves.
            case childSubpath(parentPath: String, subpath: String, minSize: Int64)
        }

        /// A file whose presence corroborates that a directory really is an artifact.
        public enum Marker: Sendable {
            /// A file beside the matched directory, e.g. `Cargo.toml` next to `target/`.
            case sibling(String)
            /// Any one of several siblings, e.g. either Gradle build file.
            case siblingAny([String])
            /// EVERY named sibling, not any. The stricter form exists for
            /// patterns that override a traversal skip, where one coincidence
            /// is not enough proof: reaching a directory called `Library`
            /// must require evidence it is a Unity project rather than
            /// `~/Library`.
            case siblingAll([String])
            /// A file inside the matched directory, e.g. `pyvenv.cfg` in `venv/`.
            case child(String)
            /// Any sibling carrying this extension, named or not. An Unreal
            /// project is identified by a `.uproject` file called after the
            /// project rather than after the engine, so there is no fixed
            /// filename for the other markers to look for.
            case siblingWithExtension(String)

            public func matches(directory: URL, fileManager: FileManager = .default) -> Bool {
                switch self {
                case .sibling(let name):
                    let sibling = directory.deletingLastPathComponent()
                        .appending(path: name, directoryHint: .notDirectory)
                    return fileManager.fileExists(atPath: sibling.path(percentEncoded: false))
                case .siblingAny(let names):
                    let parent = directory.deletingLastPathComponent()
                    return names.contains { name in
                        let sibling = parent.appending(path: name, directoryHint: .notDirectory)
                        return fileManager.fileExists(atPath: sibling.path(percentEncoded: false))
                    }
                case .siblingAll(let names):
                    let parent = directory.deletingLastPathComponent()
                    // An empty list would vacuously match everything, which
                    // for a skip-overriding marker means matching ~/Library.
                    guard names.isEmpty == false else { return false }
                    return names.allSatisfy { name in
                        let sibling = parent.appending(path: name, directoryHint: .notDirectory)
                        return fileManager.fileExists(atPath: sibling.path(percentEncoded: false))
                    }
                case .child(let name):
                    let child = directory.appending(path: name, directoryHint: .notDirectory)
                    return fileManager.fileExists(atPath: child.path(percentEncoded: false))
                case .siblingWithExtension(let ext):
                    let parent = directory.deletingLastPathComponent()
                    let names = (try? fileManager.contentsOfDirectory(
                        atPath: parent.path(percentEncoded: false))) ?? []
                    // pathExtension rather than a suffix comparison. The two
                    // differ on `Myuproject`, which ends in the letters and
                    // has no extension at all -- and which would otherwise
                    // nominate a whole project directory for deletion.
                    return names.contains { ($0 as NSString).pathExtension == ext }
                }
            }
        }
    }

    /// All scan profiles for every supported category.
    public static let all: [ScanProfile] = [
        // =========================================
        // MARK: - Developer Categories
        // =========================================

        // MARK: - Node.js
        ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
            // A version manager never removes anything:
            // nine node versions totalling ~3.6 GB, one of them in use. Each
            // is `.costly` rather than `.safe` — `nvm install` brings it back,
            // but there is no manifest saying which versions a machine had.
            .toolchainVersions(
                under: "~/.nvm/versions/node", pointer: "~/.nvm/alias/default",
                aliases: "~/.nvm/alias", tier: .costly),
        ]),

        // MARK: - Python
        ScanProfile(category: .python, patterns: [
            // pyenv's pointer names a version directly, so there is no alias
            // directory to follow — unlike nvm, whose `default` chains.
            .toolchainVersions(
                under: "~/.pyenv/versions", pointer: "~/.pyenv/version", tier: .costly),
            .dir("__pycache__", tier: .safe),
            .dir(".venv", tier: .safe),
            .dir("venv", marker: .child("pyvenv.cfg"), tier: .safe),
            .dir(".tox", tier: .safe),
            .dir(".mypy_cache", tier: .safe),
            .dir(".pytest_cache", tier: .safe),
            .dir(".ruff_cache", tier: .safe),
            .path("~/.cache/uv", tier: .costly),
        ]),

        // MARK: - Rust
        ScanProfile(category: .rust, patterns: [
            .dir("target", marker: .sibling("Cargo.toml"), tier: .safe),
        ]),

        // MARK: - Java/Kotlin
        ScanProfile(category: .javaKotlin, patterns: [
            .dir("build", marker: .siblingAny([
                "build.gradle", "build.gradle.kts",
            ]), tier: .safe),
            .dir(".gradle", marker: .siblingAny([
                "build.gradle", "build.gradle.kts",
                "settings.gradle", "settings.gradle.kts",
            ]), tier: .safe),
            .dir("target", marker: .sibling("pom.xml"), tier: .safe),
        ]),

        // MARK: - Android
        //
        // Measured on a fresh Android Studio 2026.1.4 install carrying one API
        // level: 1.8 GB under the SDK, of which 1.2 GB is the emulator binary
        // and is not listed here at all.
        //
        // What is deliberately absent: `emulator`, `platform-tools` and
        // `licenses`. None of them is versioned, all of them are the current
        // tooling, and removing any one breaks the SDK rather than freeing a
        // stale copy. The emulator being the single largest directory is
        // exactly why it needs saying — size is not the test.
        ScanProfile(category: .android, patterns: [
            // Gradle uses the highest installed build-tools unless a project
            // pins `buildToolsVersion`, so "keep the newest" is a real
            // retention here and not a guess. Same mechanism as the version
            // managers, and it fails closed the same way: if the process list
            // cannot be read, every version is retained and none is offered.
            .toolchainVersions(
                under: "~/Library/Android/sdk/build-tools",
                minSize: 10_000_000,
                tier: .costly
            ),
            // Platforms and sources are per API level, and which one is in use
            // is decided by each project's `compileSdk` -- not by which is
            // newest. So these are enumerated rather than filtered: claiming a
            // retention that cannot be computed would be worse than offering
            // both and pricing them honestly. Removing one costs an SDK
            // Manager download, which is tier 2's definition.
            //
            // `android-37.0` also does not parse as a version -- the leading
            // word collapses to zero in the comparator every version manager
            // here shares -- so the newest could not be identified even if it
            // were the right rule.
            .subdirs(of: "~/Library/Android/sdk/platforms", minSize: 10_000_000, tier: .costly),
            .subdirs(of: "~/Library/Android/sdk/sources", minSize: 10_000_000, tier: .costly),
            // Absent until the first emulator image is downloaded, then a
            // gigabyte or more per API level and hardware profile. The biggest
            // thing this category will ever find on a machine that emulates.
            .subdirs(
                of: "~/Library/Android/sdk/system-images",
                minSize: 100_000_000,
                tier: .costly
            ),
            // A virtual device holds state that exists nowhere else: the apps
            // installed inside it, its settings, whatever a test left behind.
            // Recreating the device does not bring any of that back, which is
            // the definition of tier 3 rather than tier 2.
            .subdirs(of: "~/.android/avd", minSize: 1_000_000, tier: .destructive),
        ]),

        // MARK: - Xcode & Apple Dev
        ScanProfile(category: .xcode, patterns: [
            .path("~/Library/Developer/Xcode/DerivedData", tier: .safe),
            .path("~/Library/Developer/Xcode/iOS DeviceSupport", tier: .costly),
            .path("~/Library/Developer/Xcode/watchOS DeviceSupport", tier: .costly),
            .path("~/Library/Developer/CoreSimulator/Caches", tier: .costly),
            // Simulator OS images downloaded by Xcode 13 and earlier. No user
            // data (that's the sibling `Devices` below), so a re-download,
            // not a loss. Kept because upgraded machines can strand tens of
            // GB here for years.
            .path("~/Library/Developer/CoreSimulator/Profiles/Runtimes", tier: .costly),
            // Where Xcode 14+ puts downloaded runtimes, as disk images.
            // Root-owned: shown with a real size, never offered for
            // deletion — same treatment as /Library/Caches.
            .path(
                "/Library/Developer/CoreSimulator/Images",
                tier: .costly,
                removability: .requiresPrivileges
            ),
            .path("~/Library/Developer/Xcode/DocumentationCache", tier: .costly),
            // dSYMs for shipped builds. Without them production crash reports
            // cannot be symbolicated, and they cannot be regenerated.
            .path("~/Library/Developer/Xcode/Archives", tier: .destructive),
            // Installed simulator apps and their data.
            .path("~/Library/Developer/CoreSimulator/Devices", tier: .destructive),
            .dir(".build", marker: .sibling("Package.swift"), tier: .safe),
            .dir("Pods", marker: .sibling("Podfile"), tier: .safe),
        ]),

        // MARK: - Go
        ScanProfile(category: .goLang, patterns: [
            .dir("vendor", marker: .sibling("go.mod"), tier: .safe),
            .path("~/go/pkg/mod/cache", tier: .costly),
            // Compiled build artifacts, not downloaded modules: `go build`
            // refills this from sources already on disk. Safe despite being
            // machine-wide rather than per-project.
            .path("~/Library/Caches/go-build", tier: .safe),
        ]),

        // MARK: - Docker
        ScanProfile(category: .docker, patterns: [
            // One VM disk image holding images AND volumes, with no way to
            // separate them. Deleting it destroys named volumes.
            .path("~/Library/Containers/com.docker.docker/Data", tier: .destructive),
        ]),

        // MARK: - Homebrew
        ScanProfile(category: .homebrew, patterns: [
            .path("~/Library/Caches/Homebrew", tier: .costly),
        ]),

        // MARK: - Package Caches (global)
        ScanProfile(category: .packageCaches, patterns: [
            .path("~/.npm/_cacache", tier: .costly),
            .path("~/.yarn/cache", tier: .costly),
            .path("~/.pnpm-store", tier: .costly),
            .path("~/.cargo/registry", tier: .costly),
            .path("~/.gradle/caches", tier: .costly),
            .path("~/.cache/pip", tier: .costly),
            .path("~/.gem", tier: .costly),
            .path("~/.cocoapods/repos", tier: .costly),
            .path("~/.pub-cache", tier: .costly),
            .path("~/.nuget/packages", tier: .costly),
            .path("~/.m2/repository", tier: .costly),
            .path("~/.bun/install/cache", tier: .costly),
            .path("~/Library/Caches/deno", tier: .costly),
        ]),

        // MARK: - IDE & Editor Data
        ScanProfile(category: .ideData, patterns: [
            .path("~/Library/Application Support/Code/Cache", tier: .safe),
            .path("~/Library/Application Support/Code/CachedData", tier: .safe),
            .path("~/Library/Application Support/Code/CachedExtensions", tier: .safe),
            .path("~/Library/Application Support/Code/CachedExtensionVSIXs", tier: .safe),
            .path("~/Library/Application Support/Code/User/workspaceStorage", tier: .costly),
            .path("~/Library/Caches/JetBrains", tier: .safe),
            // Installed software, not a cache.
            .path("~/.vscode/extensions", tier: .destructive),
            // Settings, keymaps, plugins, licences.
            .path("~/Library/Application Support/JetBrains", tier: .destructive),
        ]),

        // MARK: - macOS Dev Caches
        ScanProfile(category: .macDevCaches, patterns: [
            .path("~/Library/Caches/com.apple.dt.Xcode", tier: .safe),
            .path("~/Library/Caches/org.swift.swiftpm", tier: .costly),
        ]),

        // MARK: - Terraform
        ScanProfile(category: .terraform, patterns: [
            .dir(".terraform", marker: .sibling("main.tf"), tier: .safe),
        ]),

        // MARK: - Web Frameworks
        ScanProfile(category: .webFrameworks, patterns: [
            .dir(".next", tier: .safe),
            .dir(".nuxt", tier: .safe),
            .dir(".angular", tier: .safe),
        ]),

        // MARK: - Generic Build
        ScanProfile(category: .genericBuild, patterns: [
            .dir("dist", marker: .sibling("package.json"), tier: .safe),
        ]),

        // =========================================
        // MARK: - System / General Categories
        // =========================================

        // MARK: - App Caches (per-app breakdown)
        ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Library/Caches", minSize: 1_000_000, tier: .safe),
            // Containers hold user documents. Reach the cache inside each one
            // rather than enumerating the containers themselves.
            .childPath(
                in: "~/Library/Containers",
                subpath: "Data/Library/Caches",
                minSize: 5_000_000,
                tier: .safe
            ),
            // May hold cookies alongside cached responses.
            .subdirs(of: "~/Library/HTTPStorages", minSize: 500_000, tier: .costly),
        ]),

        // MARK: - Browser Data
        ScanProfile(category: .browserData, patterns: [
            .path("~/Library/Caches/com.apple.Safari", tier: .safe),
            .path("~/Library/Caches/Firefox", tier: .safe),
            .path("~/Library/Caches/company.thebrowser.Browser", tier: .safe),
            .path("~/Library/Caches/Google/Chrome", tier: .safe),
            .path("~/Library/Caches/BraveSoftware/Brave-Browser", tier: .safe),
            .path("~/Library/Caches/Microsoft Edge", tier: .safe),
            .path("~/Library/Application Support/Google/Chrome/Default/Cache", tier: .safe),
            .path("~/Library/Application Support/Google/Chrome/Default/Code Cache", tier: .safe),
            .path(
                "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cache",
                tier: .safe
            ),
            .path("~/Library/Application Support/Microsoft Edge/Default/Cache", tier: .safe),
            // Website data including live sessions.
            .path("~/Library/Safari/LocalStorage", tier: .destructive),
            .path("~/Library/Safari/Databases", tier: .destructive),
            .path("~/Library/Safari/ServiceWorkers", tier: .destructive),
            .path("~/Library/Application Support/Google/Chrome/Default/Service Worker",
                  tier: .destructive),
        ]),

        // MARK: - iOS Backups
        ScanProfile(category: .iOSBackups, patterns: [
            // May be the only copy of a device's data.
            .subdirs(of: "~/Library/Application Support/MobileSync/Backup", tier: .destructive),
        ]),

        // MARK: - Saved Application State
        ScanProfile(category: .savedState, patterns: [
            .subdirs(of: "~/Library/Saved Application State", minSize: 100_000, tier: .safe),
        ]),

        // MARK: - Mail Downloads & Data
        ScanProfile(category: .mailData, patterns: [
            // The scanner cannot tell an IMAP account from a local-only one.
            .path("~/Library/Mail Downloads", tier: .destructive),
            .path(
                "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                tier: .destructive
            ),
        ]),

        // MARK: - System Caches
        ScanProfile(category: .systemCaches, patterns: [
            .path("~/Library/Caches/CloudKit", tier: .safe),
            .path("~/Library/Caches/com.apple.helpd", tier: .safe),
            .path("~/Library/Caches/com.apple.ap.adprivacyd", tier: .safe),
            .path("~/Library/Caches/com.apple.nsurlsessiond", tier: .safe),
            .path("~/Library/Caches/com.apple.HomeKit", tier: .safe),
            .path("~/Library/Caches/GeoServices", tier: .safe),
            .path("~/Library/Caches/FamilyCircle", tier: .safe),
            .path("~/Library/Caches/com.apple.QuickLook.thumbnailcache", tier: .safe),
            .path("~/Library/Caches/com.apple.iconservices.store", tier: .safe),
            // Root-owned, shown for information only: SIP refuses parts of
            // these even to root, so no privileged helper can remove them.
            .path("/Library/Caches", tier: .costly, removability: .requiresPrivileges),
            .path("/System/Library/Caches", tier: .costly, removability: .requiresPrivileges),
        ]),

        // MARK: - Logs & Crash Reports
        ScanProfile(category: .logs, patterns: [
            .path("~/Library/Logs/DiagnosticReports", tier: .safe),
            .path("~/Library/Logs/JetBrains", tier: .safe),
            .path("~/Library/Logs/Homebrew", tier: .safe),
            .path("~/Library/Logs/Spotlight", tier: .safe),
            .path("~/Library/Logs/CoreSimulator", tier: .safe),
            .subdirs(of: "~/Library/Logs", minSize: 500_000, tier: .safe),
        ]),

        // MARK: - App Deep Clean
        //
        // Curated per-application knowledge. Sizes in comments were measured
        // on the development machine .
        //
        // Anything NOT listed here inside these same directories is excluded
        // deliberately — see UserDataDenylistTests for the paths that must never
        // appear and why.
        // =========================================
        // MARK: - Game Engines
        // =========================================
        //
        // Everything the three engines keep, in one place, because a user
        // asking "why is Godot using 4 GB" should not have to know whether a
        // given directory is per-project or machine-wide to find it.
        //
        // The engines and editors THEMSELVES are deliberately absent -- Godot.app,
        // Unity's editors, Unreal's 43 GB engine install. Those are the
        // product rather than a cache, and the Uninstall view is where an
        // installed thing is removed.
        ScanProfile(category: .gameEngines, patterns: [
            // Godot — export templates are per engine version and total ~2 GB, so
            // enumerate them individually to let old versions go one at a time.
            // Offered only for versions with no installed Godot. Measured:
            // 4.7.2 was the installed editor while both template directories
            // on disk were 4.6.1, so 2.0 GB belonged to no editor at all. The
            // same rule keeps 4.6.1's templates the moment 4.6.1 is installed
            // again, including the `.mono` variant, which shares its version.
            .engineVersions(
                under: "~/Library/Application Support/Godot/export_templates",
                engine: .godot,
                tier: .costly
            ),
            .path("~/Library/Application Support/Godot/shader_cache", tier: .safe),

            // Unreal Engine — the launcher's vault cache. This is the
            // launcher's own copy of every store asset already downloaded,
            // kept BESIDE the copy imported into a project rather than
            // instead of it, so a project keeps working when it goes. 21 GB
            // measured across eight assets, one of them 18 GB by itself,
            // which is why each asset is enumerated separately: one pack
            // should be able to go without taking the other seven.
            //
            // Costly, not safe. It refills only by re-downloading gigabytes
            // from the store, and nothing in any project describes what was
            // in it.
            //
            // Under /Users/Shared/UnrealEngine, not /Users/Shared/Epic Games
            // where the engine installs -- measured, not assumed; the two
            // sibling trees are easy to conflate.
            //
            // minSize skips FabLibrary, which is the library index (52 KB
            // measured) rather than a downloaded asset. Listing it would
            // offer a rounding error while implying the library itself is
            // disposable.
            .subdirs(
                of: "/Users/Shared/UnrealEngine/Launcher/VaultCache",
                minSize: 1_000_000,
                tier: .costly
            ),

            // Engine-wide derived data and build intermediates, reached
            // THROUGH the version directory rather than naming one. A pattern
            // spelling out UE_5.8 stops finding anything the day the engine
            // updates, and finds nothing at all on a machine that installed a
            // different version first.
            .childPath(
                in: "/Users/Shared/Epic Games", subpath: "Engine/DerivedDataCache",
                tier: .costly),
            .childPath(
                in: "/Users/Shared/Epic Games", subpath: "Engine/Intermediate",
                tier: .costly),
            .childPath(
                in: "~/Library/Application Support/Epic/UnrealEngine", subpath: "Intermediate",
                tier: .costly),

            // A whole support directory for an engine version that is no
            // longer installed. Measured: a `5.5` directory survived here long
            // after that engine went, while 5.8 was the installed one. The
            // `Intermediate` pattern above reaches an INSTALLED version's
            // cache; this reaches everything belonging to a version that has
            // no engine at all, and containment collapse folds the one into
            // the other when both match.
            //
            // The sibling `Common` directory carries no version in its name,
            // so EngineVersions never offers it -- which matters, because it
            // holds the derived data cache and Zen store of whatever engine IS
            // installed.
            .engineVersions(
                under: "~/Library/Application Support/Epic/UnrealEngine",
                engine: .unreal,
                tier: .costly),

            // Shared by every project on the machine, which is what makes
            // these costly however automatically they refill.
            .path(
                "~/Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache",
                tier: .costly),
            // Zen is Unreal's storage server. Only its Data is cache: the
            // sibling Install holds the server's own binaries, so targeting
            // the Zen directory whole would take the server with it.
            .path(
                "~/Library/Application Support/Epic/UnrealEngine/Common/Zen/Data",
                tier: .costly),

            // Store thumbnails, refetched silently the next time the launcher
            // opens.
            .path(
                "~/Library/Application Support/Epic/EpicGamesLauncher/Data/ContentCache",
                tier: .safe),

            // The engine install itself is deliberately absent. 43 GB
            // measured, and every byte of it is the product rather than a
            // cache -- removing it is an uninstall, not a clean.

            // Unity — the asset store's local copy of every package
            // downloaded, 1.7 GB measured across five publishers. Same shape
            // as Unreal's vault cache and costly for the same reason: it
            // refills only by re-downloading and no project describes what
            // was in it. Laid out by publisher rather than by asset, so that
            // is the granularity a row can have.
            //
            // Enumerated from `Asset Store-5.x` and never from `~/Library/Unity`
            // above it, which also holds `licenses` -- the machine's Unity
            // activation. A sweep one level up would take the licence with
            // the cache. See noPatternSweepsTheUnityLibraryRootOrItsLicences.
            .subdirs(
                of: "~/Library/Unity/Asset Store-5.x",
                minSize: 1_000_000,
                tier: .costly
            ),

            // Unity keeps every editor version ever installed, each in its
            // own directory and each measured at 17 GB. Offered only for
            // versions nothing retains: no project pins them, and they are not
            // the newest. See `retainedEditorVersions` -- Unity is the one
            // engine where "is it installed" cannot be the rule, because these
            // directories ARE the installs.
            //
            // Costly rather than destructive: an editor comes back from the
            // Hub, at real bandwidth and with no manifest describing what was
            // there.
            .engineVersions(
                under: "/Applications/Unity/Hub/Editor",
                engine: .unity,
                tier: .costly),

            // Downloaded project scaffolds, 336 MB measured.
            .path(
                "~/Library/Application Support/UnityHub/Templates", tier: .costly),
            // The Hub's own working cache, which it rebuilds unprompted.
            .path("~/Library/Application Support/UnityHub/Cache", tier: .safe),

            // Everything Unity keeps under ~/Library/Caches is already
            // reached by the appCaches sweep of that directory -- UnityHub,
            // com.unity3d.unityhub.ShipIt and com.unity3d.UnityEditor, 960 MB
            // between them. Repeating them here would add rows, not reach.
            //
            // The 28 GB of editors under /Applications/Unity/Hub is absent
            // for the same reason the Unreal engine is: it is the product.

            // Unreal project artifacts. Each is gated on the `.uproject`
            // beside it, which is what separates a project's Intermediate
            // from the engine's own -- the engine has these directories too,
            // in a directory with no `.uproject` in it, and they are reached
            // deliberately by path in `appDeepClean` instead.
            //
            // Safe rather than costly: one deletion affects one project, and
            // the editor rebuilds all three from the project's own content
            // with no download. Slow to rebuild is not the same as costly.
            .dir("Intermediate", marker: .siblingWithExtension("uproject"), tier: .safe),
            .dir("DerivedDataCache", marker: .siblingWithExtension("uproject"), tier: .safe),
            .dir("Binaries", marker: .siblingWithExtension("uproject"), tier: .safe),

            // Godot's per-project import cache. 1.53 GB across five projects
            // measured, the largest 908 MB. Rebuilt by reimporting the
            // project's own assets when the editor next opens it, which is
            // why it is in every Godot .gitignore.
            //
            // `project.godot` is the file that defines a Godot project and
            // sits beside the cache, so one sibling is proof enough here --
            // unlike Unity's `Library`, `.godot` is a name nothing else uses
            // and the walk does not skip it.
            .dir(".godot", marker: .sibling("project.godot"), tier: .safe),

            // Unity's import cache, 2.0 GB measured on a nearly empty
            // project and the largest thing Unity leaves anywhere. Rebuilt by
            // reopening the project, from `Packages/manifest.json` -- which is
            // literally the manifest the safe tier is defined by.
            //
            // `Library` is in FileScanner.skipDirectories, so this pattern
            // claims a name the walk otherwise refuses. That is allowed only
            // for a marked pattern, and the marker demands BOTH `Assets` and
            // `ProjectSettings` rather than either: a single coincidence
            // beside a directory called Library is not enough evidence when
            // the cost of being wrong is offering someone their ~/Library.
            // The walk still never descends into it.
            .dir(
                "Library",
                marker: .siblingAll(["Assets", "ProjectSettings"]),
                tier: .safe
            ),

            // `Saved/` is deliberately absent. It holds Autosaves and Config
            // alongside its logs and shader debug output, so there is no tier
            // at which sweeping it whole is right -- see
            // noPatternSweepsAnUnrealProjectsSavedDirectory.

            // `Saved/` is deliberately absent. It holds Autosaves and Config
            // alongside its logs and shader debug output, so there is no tier
            // at which sweeping it whole is right -- see
            // noPatternSweepsAnUnrealProjectsSavedDirectory.
        ]),

        ScanProfile(category: .appDeepClean, patterns: [
            // Claude Desktop — VM image for sandboxed code execution. 11 GB.
            // Re-downloaded automatically, so costly rather than destructive.
            .path("~/Library/Application Support/Claude/vm_bundles", tier: .costly),
            // Claude Desktop — Electron and Chromium caches.
            .path("~/Library/Application Support/Claude/Code Cache", tier: .safe),
            .path("~/Library/Application Support/Claude/GPUCache", tier: .safe),
            .path("~/Library/Application Support/Claude/DawnWebGPUCache", tier: .safe),
            .path("~/Library/Application Support/Claude/DawnGraphiteCache", tier: .safe),

            // VS Code — CachedExtensionVSIXs is intentionally absent; the ideData
            // profile already covers it.
            .path("~/Library/Application Support/Code/WebStorage", tier: .costly),
            .path("~/Library/Application Support/Code/logs", tier: .safe),
            .path("~/Library/Application Support/Code/blob_storage", tier: .safe),
            .path("~/Library/Application Support/Code/Crashpad", tier: .safe),
            .path("~/Library/Application Support/Code/CachedProfilesData", tier: .safe),

            // CLI tool caches.
            .path("~/.codex/cache", tier: .safe),
            .path("~/.claude/cache", tier: .safe),
        ]),
    ]
}

extension ScanProfile.Pattern {
    public static func dir(
        _ name: String, marker: Marker? = nil, tier: RemovalTier
    ) -> Self {
        .init(kind: .directoryName(name, marker: marker), tier: tier)
    }

    public static func path(
        _ path: String, tier: RemovalTier, removability: Removability = .removable
    ) -> Self {
        .init(kind: .absolutePath(path), tier: tier, removability: removability)
    }

    public static func subdirs(
        of parentPath: String, minSize: Int64 = 0, tier: RemovalTier
    ) -> Self {
        .init(kind: .subdirectories(parentPath: parentPath, minSize: minSize), tier: tier)
    }

    /// Installed toolchain versions that nothing is using — see
    /// `ToolchainVersions` for the three retentions and what each is worth.
    public static func toolchainVersions(
        under parentPath: String,
        pointer: String? = nil,
        aliases: String? = nil,
        minSize: Int64 = 0,
        tier: RemovalTier
    ) -> Self {
        .init(
            kind: .toolchainVersions(
                parentPath: parentPath, pointerPath: pointer, aliasDirectory: aliases,
                minSize: minSize),
            tier: tier)
    }

    public static func engineVersions(
        under parentPath: String, engine: EngineVersions.Engine,
        minSize: Int64 = 0, tier: RemovalTier
    ) -> Self {
        .init(
            kind: .engineVersions(parentPath: parentPath, engine: engine, minSize: minSize),
            tier: tier)
    }

    public static func childPath(
        in parentPath: String, subpath: String, minSize: Int64 = 0, tier: RemovalTier
    ) -> Self {
        .init(
            kind: .childSubpath(parentPath: parentPath, subpath: subpath, minSize: minSize),
            tier: tier
        )
    }
}

extension ScanProfile {
    /// Expands a `~`-prefixed profile path against the current user's home.
    public static func expand(_ rawPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .path(percentEncoded: false)
        guard rawPath.hasPrefix("~") else { return rawPath }
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        return trimmedHome + rawPath.dropFirst()
    }

    /// Every literal path declared in `all`, expanded and standardized.
    /// These are audited by construction, so `PathGuard` admits them
    /// regardless of how shallow they are.
    public static var declaredAbsolutePaths: Set<String> {
        var paths = Set<String>()
        for profile in all {
            for pattern in profile.patterns {
                switch pattern.kind {
                case .absolutePath(let raw):
                    // isDirectory pinned to false to avoid a filesystem stat:
                    // these paths are compared as opaque strings, and without
                    // pinning, standardization would append a trailing slash
                    // whenever the path happens to exist as a real directory
                    // on the running machine.
                    paths.insert(
                        URL(fileURLWithPath: expand(raw), isDirectory: false).standardizedFileURL
                            .path(percentEncoded: false)
                    )
                case .directoryName, .subdirectories, .childSubpath, .toolchainVersions, .engineVersions:
                    continue
                }
            }
        }
        return paths
    }

    /// Every root a `.toolchainVersions` pattern enumerates.
    ///
    /// Deliberately separate from `declaredAbsolutePaths` rather than folded
    /// into it. That set is also `PathGuard`'s audited-by-construction
    /// exemption, and admitting `~/.nvm/versions/node` there would exempt the
    /// *container of every installed version* from the depth rules — one
    /// selection away from removing the version in use along with the rest.
    /// The Files view needs the prefix; the guard must not have it.
    public static var declaredToolchainRoots: Set<String> {
        var paths = Set<String>()
        for profile in all {
            for pattern in profile.patterns {
                guard case .toolchainVersions(let parent, _, _, _) = pattern.kind else { continue }
                paths.insert(
                    URL(fileURLWithPath: expand(parent), isDirectory: false).standardizedFileURL
                        .path(percentEncoded: false))
            }
        }
        return paths
    }

    /// Every directory name matched by a `.directoryName` pattern.
    ///
    /// The mirror of `declaredAbsolutePaths`, and the second of the three
    /// sources `FinderSkipList` unions. Derived rather than hand-listed so
    /// that adding a pattern to the table above automatically stops the
    /// Files view reporting the same bytes the Caches view already explains.
    public static var declaredDirectoryNames: Set<String> {
        var names = Set<String>()
        for profile in all {
            for pattern in profile.patterns {
                switch pattern.kind {
                case .directoryName(let name, _):
                    names.insert(name)
                case .absolutePath, .subdirectories, .childSubpath, .toolchainVersions, .engineVersions:
                    continue
                }
            }
        }
        return names
    }
}
