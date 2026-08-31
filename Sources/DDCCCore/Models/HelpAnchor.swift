import Foundation

/// Stable identifiers linking a catalogue entry to its place in the help book.
///
/// Written out rather than derived from `rawValue`: those are display strings,
/// so `CleanCategory.nodeJS` reads "Node.js". Slugging a display string means
/// editing user-visible copy silently breaks every link that points at it.
/// An exhaustive switch also means a new case does not compile until someone
/// decides its anchor, which is the guarantee the catalogue already gives.

extension RemovalTier {
    public var helpAnchor: String {
        switch self {
        case .safe: return "tier-safe"
        case .costly: return "tier-costly"
        case .destructive: return "tier-destructive"
        }
    }
}

extension Removability {
    public var helpAnchor: String {
        switch self {
        case .removable: return "removability-removable"
        case .requiresPrivileges: return "removability-requires-privileges"
        }
    }
}

extension CleanCategory {
    public var helpAnchor: String {
        switch self {
        case .nodeJS: return "category-nodejs"
        case .python: return "category-python"
        case .rust: return "category-rust"
        case .javaKotlin: return "category-java-kotlin"
        case .xcode: return "category-xcode"
        case .goLang: return "category-go"
        case .docker: return "category-docker"
        case .homebrew: return "category-homebrew"
        case .packageCaches: return "category-package-caches"
        case .ideData: return "category-ide-editor"
        case .macDevCaches: return "category-macos-dev-caches"
        case .terraform: return "category-terraform"
        case .webFrameworks: return "category-web-frameworks"
        case .genericBuild: return "category-build-output"
        case .appCaches: return "category-app-caches"
        case .browserData: return "category-browser-data"
        case .iOSBackups: return "category-ios-backups"
        case .savedState: return "category-saved-app-state"
        case .mailData: return "category-mail-downloads"
        case .systemCaches: return "category-system-caches"
        case .logs: return "category-logs-crashes"
        case .appDeepClean: return "category-app-deep-clean"
        case .gameEngines: return "category-game-engines"
        }
    }
}

extension FinderHelpTopic {
    public var helpAnchor: String {
        switch self {
        case .mode: return "files-mode"
        case .find: return "files-find"
        case .stop: return "files-stop"
        case .root: return "files-root"
        case .sizeThreshold: return "files-size-threshold"
        case .ageThreshold: return "files-age-threshold"
        case .rowCheckbox: return "files-row-checkbox"
        case .deselectAll: return "files-deselect-all"
        case .trash: return "files-trash"
        case .reveal: return "files-reveal"
        case .partialSize: return "files-partial-size"
        }
    }
}
