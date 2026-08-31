import Foundation

public enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    // Developer
    case nodeJS = "Node.js"
    case python = "Python"
    case rust = "Rust"
    case javaKotlin = "Java/Kotlin"
    case xcode = "Xcode"
    case goLang = "Go"
    case docker = "Docker"
    case homebrew = "Homebrew"
    case packageCaches = "Package Caches"
    case ideData = "IDE & Editor"
    case macDevCaches = "macOS Dev Caches"
    case terraform = "Terraform"
    case webFrameworks = "Web Frameworks"
    case genericBuild = "Build Output"
    case gameEngines = "Game Engines"
    // System / General
    case appCaches = "App Caches"
    case browserData = "Browser Data"
    case iOSBackups = "iOS Backups"
    case savedState = "Saved App State"
    case mailData = "Mail Downloads"
    case systemCaches = "System Caches"
    case logs = "Logs & Crashes"
    case appDeepClean = "App Deep Clean"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .nodeJS: return "cube.box"
        case .python: return "ladybug"
        case .rust: return "gearshape.2"
        case .javaKotlin: return "cup.and.saucer"
        case .xcode: return "hammer"
        case .goLang: return "hare"
        case .docker: return "shippingbox"
        case .homebrew: return "mug"
        case .packageCaches: return "archivebox"
        case .ideData: return "text.badge.star"
        case .macDevCaches: return "internaldrive"
        case .terraform: return "cloud"
        case .webFrameworks: return "globe"
        case .genericBuild: return "wrench.and.screwdriver"
        case .gameEngines: return "gamecontroller"
        case .appCaches: return "folder.badge.questionmark"
        case .browserData: return "safari"
        case .iOSBackups: return "iphone"
        case .savedState: return "clock.arrow.circlepath"
        case .mailData: return "envelope"
        case .systemCaches: return "gear"
        case .logs: return "doc.text"
        case .appDeepClean: return "sparkles"
        }
    }

    public var isDeveloper: Bool {
        switch self {
        case .nodeJS, .python, .rust, .javaKotlin, .xcode, .goLang, .docker,
             .homebrew, .packageCaches, .ideData, .macDevCaches, .terraform,
             .webFrameworks, .genericBuild, .gameEngines:
            return true
        default:
            return false
        }
    }
}
