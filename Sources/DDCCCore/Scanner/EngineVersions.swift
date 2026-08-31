import Foundation

/// Which version-keyed engine payloads are dead weight, and which belong to an
/// engine that is still installed.
///
/// A game engine keeps a directory per version of everything it downloads, and
/// upgrading the editor does not remove the old one. Measured on this
/// development machine: Godot 4.7.2 installed, and every export template on
/// disk was 4.6.1 -- 2.0 GB belonging to no installed editor.
///
/// The retention rule, and not the enumeration, is the product here, exactly as
/// in `ToolchainVersions`. Its rules do not transfer: a version manager points
/// at a current version through alias files and running processes, while an
/// engine's answer is simply whether an editor of that version is installed.
///
/// Both directions fail closed. A directory whose name carries no version is
/// never offered, because a rule that does not understand a name has no
/// business deleting it; and an empty install list offers nothing at all,
/// because "no engine is installed" means the engine was removed, which is the
/// Uninstall view's business rather than this rule's.
public enum EngineVersions {

    /// Where an engine's installed versions are read from, and how.
    ///
    /// A small curated enum rather than one rule, because the three engines
    /// genuinely differ: Godot writes its version into the app bundle's own
    /// Info.plist, while Unreal and Unity each name a directory per version,
    /// in different roots and with different spellings.
    public enum Engine: String, Sendable, CaseIterable {
        case godot
        case unreal
        case unity

        /// The roots this engine's versions live under on a real machine.
        /// Injectable in tests; a root that does not exist contributes
        /// nothing rather than failing.
        public var defaultRoots: [URL] {
            switch self {
            case .godot:
                return [URL(fileURLWithPath: "/Applications", isDirectory: true)]
            case .unreal:
                return [URL(fileURLWithPath: "/Users/Shared/Epic Games", isDirectory: true)]
            case .unity:
                return [URL(fileURLWithPath: "/Applications/Unity/Hub/Editor", isDirectory: true)]
            }
        }

        public func installedVersions(searching roots: [URL]? = nil) -> Set<String> {
            var found: Set<String> = []
            for root in roots ?? defaultRoots {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil)) ?? []
                for entry in entries {
                    switch self {
                    case .godot:
                        // Matched on the bundle name rather than the bundle id:
                        // the id is read from the same plist we are about to
                        // open, so a name test avoids opening every app in
                        // /Applications to ask.
                        let name = entry.lastPathComponent
                        guard name.hasPrefix("Godot"), name.hasSuffix(".app") else { continue }
                        let plist = entry.appending(path: "Contents/Info.plist")
                        guard let data = try? Data(contentsOf: plist),
                              let parsed = try? PropertyListSerialization.propertyList(
                                from: data, format: nil) as? [String: Any],
                              let version = parsed["CFBundleShortVersionString"] as? String
                        else { continue }
                        found.insert(version)
                    case .unreal, .unity:
                        // The directory name IS the version: `UE_5.8`,
                        // `6000.5.10f1`. `numericCore` does the normalising.
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(
                            atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory),
                            isDirectory.boolValue
                        else { continue }
                        found.insert(entry.lastPathComponent)
                    }
                }
            }
            return found
        }

        /// Editor versions that must not be offered.
        ///
        /// Unity is the one engine whose version directories ARE the installs,
        /// so "is it installed" cannot be the rule -- every version would
        /// retain itself and nothing would ever be offered. What makes an
        /// editor stale is that nothing needs it.
        ///
        /// Two retentions. **Any version a project pins**: a Unity project
        /// records its editor in ProjectSettings/ProjectVersion.txt and will
        /// not open under another, so deleting a pinned editor breaks that
        /// project until a re-download measured at 17 GB. The Hub records the
        /// same pin per project in projects-v1.json, which is what makes this
        /// answerable at all. And **the newest installed**, which is what a
        /// fresh install would give back and which the Uninstall view is the
        /// place to remove.
        ///
        /// Fails closed twice over. An unreadable or unparseable registry
        /// retains everything, because a rule that cannot see what projects
        /// need must not conclude that they need nothing; and a version whose
        /// name carries no number is retained by `stale` for the same reason.
        public func retainedEditorVersions(
            among versionNames: [String], registry: URL? = nil
        ) -> Set<String> {
            let cores = versionNames.compactMap { EngineVersions.numericCore(of: $0) }

            let registryURL = registry ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/UnityHub/projects-v1.json")
            guard let data = try? Data(contentsOf: registryURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let projects = root["data"] as? [String: Any]
            else {
                // Every version, so nothing is offered.
                return Set(cores)
            }

            var retained: Set<String> = []
            for (_, value) in projects {
                guard let entry = value as? [String: Any],
                      let version = entry["version"] as? String,
                      let core = EngineVersions.numericCore(of: version)
                else { continue }
                retained.insert(core)
            }

            // The newest, by numeric component rather than by string: "10"
            // sorts before "6" alphabetically, which would retain the wrong
            // editor and offer the one in use.
            if let newest = cores.max(by: { EngineVersions.isOrderedBefore($0, $1) }) {
                retained.insert(newest)
            }
            return retained
        }
    }

    /// Compares two version cores component by component as numbers.
    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// The leading run of dotted numbers in a directory or version name.
    ///
    /// Three real shapes have to survive it. Godot writes `4.6.1.stable` and
    /// `4.6.1.stable.mono`, so the run has to stop at a component that is not
    /// a number. Unreal writes `UE_5.8`, so it cannot start at the first
    /// character. Unity writes `6000.5.10f1`, so it cannot stop at the first
    /// component that is not *entirely* a number either -- the last one is
    /// `10f1` and the `10` is part of the version.
    public static func numericCore(of raw: String) -> String? {
        // Everything before the first digit is a vendor prefix: `UE_`.
        guard let firstDigit = raw.firstIndex(where: \.isNumber) else { return nil }
        let trimmed = raw[firstDigit...]

        var components: [String] = []
        for component in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            if component.allSatisfy(\.isNumber), component.isEmpty == false {
                components.append(String(component))
                continue
            }
            // A partly numeric component contributes its digits and ends the
            // run: `10f1` gives `10`, and `stable` gives nothing.
            let digits = component.prefix { $0.isNumber }
            if digits.isEmpty == false { components.append(String(digits)) }
            break
        }
        return components.isEmpty ? nil : components.joined(separator: ".")
    }

    /// Version directories with no installed engine of the same version.
    ///
    /// Order follows `directories`, so a caller's enumeration order survives.
    public static func stale(among directories: [URL], retaining retained: Set<String>) -> [URL] {
        let retainedCores = Set(retained.compactMap { numericCore(of: $0) })
        guard retainedCores.isEmpty == false else { return [] }

        return directories.filter { directory in
            guard let core = numericCore(of: directory.lastPathComponent) else { return false }
            return retainedCores.contains(core) == false
        }
    }
}
