// Sources/DDCCCore/Models/HelpText.swift
import Foundation

/// One piece of explanatory copy, in the two lengths the app needs.
///
/// Both forms live in one place so the tooltip and the help book render the
/// same words rather than two copies of the same intent. Entries keyed by an
/// enum are written as exhaustive switches, so adding a category or a tier does
/// not compile until its help exists.
public struct HelpText: Sendable, Equatable {
    /// Tooltip length. One sentence, no trailing context.
    public let short: String
    /// Help-book length. Explains the consequence, not just the control.
    public let long: String

    public init(short: String, long: String) {
        self.short = short
        self.long = long
    }
}

extension HelpText {

    public static func `for`(_ tier: RemovalTier) -> HelpText {
        switch tier {
        case .safe:
            return HelpText(
                short: tier.explanation,
                long: "Usually local build output or app cache data. Removing it should only "
                    + "affect the project or app that created it, and it can be rebuilt from "
                    + "files already on your Mac."
            )
        case .costly:
            return HelpText(
                short: tier.explanation,
                long: "Shared cache or support data. It can come back, but rebuilding it may "
                    + "take time, bandwidth, or a large download used by more than one project."
            )
        case .destructive:
            return HelpText(
                short: tier.explanation,
                long: "May contain backups, settings, user data, or files that are hard to "
                    + "recreate. Review these one at a time before selecting them."
            )
        }
    }

    public static func `for`(_ removability: Removability) -> HelpText {
        switch removability {
        case .removable:
            return HelpText(
                short: "DDCC can remove this.",
                long: "DDCC can remove this path with your current permissions."
            )
        case .requiresPrivileges:
            return HelpText(
                short: "Shown for information. DDCC cannot remove this.",
                long: "This path is shown so you can see where space is used, but DDCC cannot "
                    + "remove it with your current permissions. Some system paths are protected "
                    + "by macOS even from administrator tools."
            )
        }
    }

    /// Exhaustive on purpose: a new category must not reach the interface
    /// without copy explaining what it is.
    public static func `for`(_ category: CleanCategory) -> HelpText {
        switch category {
        case .nodeJS:
            return HelpText(
                short: "Installed npm packages, and node versions you no longer use.",
                long: "node_modules directories inside projects, reinstalled with npm, yarn or "
                    + "pnpm from the project's lockfile. Also node versions kept by nvm that "
                    + "nothing is using: the newest, the one nvm's own alias points at, and any "
                    + "version a running process is using are never offered. A version you do "
                    + "remove comes back with nvm install, so it is tier 2."
            )
        case .python:
            return HelpText(
                short: "Virtual environments and interpreter caches.",
                long: "Virtual environments, __pycache__, and the caches left by pytest, mypy, "
                    + "tox and ruff, all of which live beside a project and are recreated from "
                    + "its requirements. The uv download cache in ~/.cache/uv is shared by every "
                    + "project instead, so removing it costs a re-download rather than a rebuild "
                    + "— which is why it is tier 2 and the rest are tier 1. Python versions "
                    + "installed by pyenv are listed on the same terms as node versions: the "
                    + "newest, the one pyenv points at, and any version in use are held back."
            )
        case .rust:
            return HelpText(
                short: "Cargo build output inside your projects.",
                long: "target directories next to Cargo.toml. Rebuild them with cargo build."
            )
        case .javaKotlin:
            return HelpText(
                short: "Gradle and Maven build output.",
                long: "build, .gradle, and target directories next to Gradle or Maven project "
                    + "files. Rebuild them with the project's build command."
            )
        case .xcode:
            return HelpText(
                short: "Xcode build output, device support and simulator data.",
                long: "DerivedData rebuilds on the next build. Device support and simulator "
                    + "runtimes can be downloaded again. Xcode Archives and simulator Devices "
                    + "may contain crash-symbol files, installed apps, and simulator data, so "
                    + "review those carefully."
            )
        case .goLang:
            return HelpText(
                short: "Go module vendoring and the build cache.",
                long: "The Go build cache recompiles from local source. The module download "
                    + "cache can be fetched again when a project needs it."
            )
        case .docker:
            return HelpText(
                short: "Docker's virtual machine disk image.",
                long: "Docker Desktop stores images and named volumes together in its data "
                    + "directory. Removing it can remove volume data as well as images."
            )
        case .homebrew:
            return HelpText(
                short: "Downloaded Homebrew bottles and sources.",
                long: "Downloaded Homebrew packages and source archives. Homebrew downloads "
                    + "them again when an install or upgrade needs them."
            )
        case .packageCaches:
            return HelpText(
                short: "Global package manager download caches.",
                long: "Download caches for npm, pnpm, Cargo, Gradle, pip, Maven, NuGet, and "
                    + "similar tools. They can be fetched again, but removing them may slow "
                    + "the next build or install."
            )
        case .ideData:
            return HelpText(
                short: "Editor caches, and some editor state that is not a cache.",
                long: "The VS Code and JetBrains caches rebuild on next launch. Workspace "
                    + "storage in Code/User/workspaceStorage is not a cache: it holds each "
                    + "project's editor state — open files, undo history, per-workspace "
                    + "extension data — which comes back empty rather than rebuilt, so it is "
                    + "tier 2. Installed extensions and JetBrains application support hold "
                    + "settings, keymaps and licences, which is why they are tier 3."
            )
        case .macDevCaches:
            return HelpText(
                short: "Xcode and Swift Package Manager caches.",
                long: "Xcode cache data can be recreated from the installed toolchain. Swift "
                    + "Package Manager cache data may need to download again."
            )
        case .terraform:
            return HelpText(
                short: "Downloaded Terraform providers and modules.",
                long: ".terraform directories next to Terraform configuration. Restore them "
                    + "with terraform init."
            )
        case .webFrameworks:
            return HelpText(
                short: "Next.js, Nuxt and Angular build output.",
                long: "Framework build output such as .next, .nuxt, and .angular. Rebuild it "
                    + "with the project's build or dev command."
            )
        case .genericBuild:
            return HelpText(
                short: "dist directories beside a package.json.",
                long: "dist directories next to package.json. Rebuild them with the project's "
                    + "build script."
            )
        case .appCaches:
            return HelpText(
                short: "Per-application caches under ~/Library/Caches.",
                long: "Per-app cache folders under ~/Library/Caches and app container caches. "
                    + "HTTPStorages may include website data such as cookies, so review that "
                    + "category before enabling it."
            )
        case .browserData:
            return HelpText(
                short: "Browser caches, and some browser storage that is not a cache.",
                long: "Browser caches can be downloaded again as you browse. Local storage, "
                    + "databases, and service workers may hold site data or sessions, so they "
                    + "are treated as destructive."
            )
        case .iOSBackups:
            return HelpText(
                short: "Local backups of iOS devices.",
                long: "Local iPhone and iPad backups. They may be the only copy of a device's "
                    + "data; DDCC cannot tell whether the same device is backed up elsewhere."
            )
        case .savedState:
            return HelpText(
                short: "Saved window positions and restored documents.",
                long: "Saved application state used to reopen windows and documents after an "
                    + "app relaunch. Removing it resets that restore state."
            )
        case .mailData:
            return HelpText(
                short: "Mail attachments saved to disk.",
                long: "Mail downloads and attachments stored locally. Some accounts can "
                    + "download them again; local-only mail may not."
            )
        case .systemCaches:
            return HelpText(
                short: "macOS component caches.",
                long: "Cache data created by macOS services. User-owned caches can be rebuilt "
                    + "by the system. Root-owned caches are shown for information only."
            )
        case .logs:
            return HelpText(
                short: "Log files and crash reports.",
                long: "Diagnostic logs and crash reports. Removing them frees space but also "
                    + "removes history you may want for troubleshooting."
            )
        case .android:
            return HelpText(
                short: "SDK platforms, sources, build tools and emulator images, per version.",
                long: "The Android SDK keeps a copy of everything it has ever downloaded. "
                    + "Platforms and sources are per API level, system images are per API "
                    + "level and hardware profile at a gigabyte or more each, and build "
                    + "tools are per version. All of them come back from the SDK Manager, "
                    + "so they are tier 2. Build tools follow the same rule as the version "
                    + "managers: the newest is never offered, because Gradle uses it unless "
                    + "a project pins another. Platforms and sources are listed whole, "
                    + "since which one is in use depends on each project's compileSdk "
                    + "rather than on which is newest. Virtual devices are tier 3 -- an "
                    + "emulator holds the apps installed inside it and whatever state they "
                    + "left, and recreating the device does not bring that back. The "
                    + "emulator itself, the platform tools and the licences are never "
                    + "listed: they are the current toolchain, not a spare copy of it."
            )
        case .gameEngines:
            return HelpText(
                short: "Engine downloads and caches, including versions you no longer run.",
                long: "Export templates, derived data and store downloads kept by Godot, "
                    + "Unity and Unreal. A version's files are listed only when no editor "
                    + "of that version is installed. The engines themselves are not listed "
                    + "here; remove those from the Uninstall view."
            )
        case .appDeepClean:
            return HelpText(
                short: "Curated per-application caches beyond the standard locations.",
                long: "Known cache and support-data locations for specific apps. DDCC only "
                    + "lists paths it recognizes; nearby app data is left alone."
            )
        }
    }
}

// MARK: - Files view
//
// The Files view's help entries live on FinderHelpTopic, not here — see
// Sources/DDCCCore/Models/FinderHelpTopic.swift.
