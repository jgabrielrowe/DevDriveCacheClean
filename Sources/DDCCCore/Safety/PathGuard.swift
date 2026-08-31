// Sources/DDCCCore/Safety/PathGuard.swift
import Foundation

/// Deny-by-default validation for any path the app might delete.
///
/// Enforced twice: once in `CandidateResolver` to filter scan results, and
/// again in `DeletionService` immediately before each removal, so a defect in
/// the selection UI cannot route around it.
public enum PathGuard {

    public enum Verdict: Sendable, Equatable {
        case allowed
        /// Scannable and displayable, never deletable.
        case lockedInformational
        case refused(reason: String)

        public var isAllowed: Bool { self == .allowed }
    }

    public struct Context: Sendable {
        /// The root the user chose to scan, with symlinks resolved so it
        /// compares consistently against the resolved candidate paths
        /// `evaluate` derives from `url`.
        public let scanRoot: URL
        /// Standardized absolute paths declared literally in `ScanProfile.all`,
        /// normalized the same way candidate paths are. Audited by
        /// construction, so they pass regardless of depth.
        public let declaredPaths: Set<String>

        public init(scanRoot: URL, declaredPaths: Set<String>) {
            self.scanRoot = scanRoot.standardizedFileURL.resolvingSymlinksInPath()
            self.declaredPaths = Set(declaredPaths.map { raw in
                PathGuard.normalizedPathString(
                    URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
                )
            })
        }
    }

    /// The refusal reason for a path that is not on disk.
    ///
    /// Public because a caller needs to tell this refusal from every other
    /// one. Absence is still a refusal — nothing that is not there may ever
    /// be deleted — but it is the only refusal that says *nothing is being
    /// withheld*, so a disclosure list built to say "this app owns more
    /// than what is offered above" must not carry it. Every other refusal
    /// names real bytes this engine declined to touch.
    public static let doesNotExistReason = "path does not exist"

    /// The one refusal a user can clear by authenticating; see
    /// `requiresElevation`.
    public static let rootOwnedReason = "path is owned by root"

    /// Absolute paths that are never deletable, whatever the scan root is.
    static let forbiddenExactPaths: Set<String> = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/cores",
        "/etc", "/var", "/tmp", "/private", "/opt", "/Applications",
        "/Users", "/Volumes", "/Network", "/dev",
    ]

    /// Directories directly inside home that hold user documents.
    static let protectedHomeChildren: Set<String> = [
        "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies",
        "Library", "Applications", "Public", "Sites", "iCloud Drive",
    ]

    /// Every macOS account's home lives directly under here, whether or not
    /// it belongs to the user running this process.
    private static let usersDirectoryPath = "/Users"

    public static func evaluate(
        _ url: URL,
        removability: Removability,
        in context: Context
    ) -> Verdict {
        evaluate(url, removability: removability, in: context, ignoringRootOwnership: false)
    }

    /// Whether root ownership is the *only* thing standing between this path
    /// and `.allowed` — and the path is one the caller explicitly declared.
    ///
    /// Measured: `FileManager.trashItem` refuses an item the user
    /// does not own even when the containing directory is writable, so a
    /// pkg-installed app cannot be removed unprivileged. Finder performs the
    /// same move after authenticating. That makes root ownership the one
    /// refusal a user can actually clear, which is why it gets a question of
    /// its own rather than being folded into `evaluate`'s verdict: every
    /// existing caller keeps failing closed on root-owned paths, and only a
    /// caller that has an authenticated removal route asks this.
    ///
    /// The declared-path requirement is what keeps this a door rather than a
    /// hole. Without it, any root-owned directory deep enough under the scan
    /// root would qualify by way of the ordinary depth rules — `/Library`'s
    /// contents included. With it, the only paths that can qualify are the
    /// ones the caller named, which at the sole call site is an identity's own
    /// `.app` bundle. Every other rule — symlinks, traversal, home
    /// directories, volume roots, absence — still refuses, and is tested to.
    public static func requiresElevation(
        _ url: URL,
        removability: Removability,
        in context: Context
    ) -> Bool {
        guard
            evaluate(url, removability: removability, in: context)
                == .refused(reason: rootOwnedReason)
        else { return false }

        let resolvedPath = normalizedPathString(
            url.standardizedFileURL.resolvingSymlinksInPath())
        guard context.declaredPaths.contains(resolvedPath) else { return false }

        return evaluate(url, removability: removability, in: context, ignoringRootOwnership: true)
            == .allowed
    }

    private static func evaluate(
        _ url: URL,
        removability: Removability,
        in context: Context,
        ignoringRootOwnership: Bool
    ) -> Verdict {
        if removability == .requiresPrivileges {
            return .lockedInformational
        }

        // Checked before any path-string logic — don't rely on
        // FileManager.removeItem rejecting a non-file scheme downstream.
        guard url.isFileURL else {
            return .refused(reason: "path is not a file URL")
        }

        // Reject before standardization so traversal cannot be normalized away.
        if url.pathComponents.contains("..") {
            return .refused(reason: "path contains a parent-directory traversal")
        }

        let standardized = url.standardizedFileURL
        let path = normalizedPathString(standardized)

        // Not dead code: a `file:` URL built with no path at all standardizes
        // to an empty string, which fails this check (a relative *string*
        // can't reach here — `URL(fileURLWithPath:)` always absolutizes
        // against the cwd). `relativePathIsRefused` mutation-tests this branch.
        guard path.hasPrefix("/") else {
            return .refused(reason: "path is not absolute")
        }

        // Never delete a symlink outright. Probed on this unresolved form —
        // resolvingSymlinksInPath must not run before this check, or a leaf
        // symlink would be silently followed rather than refused.
        if isSymbolicLink(standardized) {
            return .refused(reason: "path is a symbolic link")
        }

        // Resolve symlinks in the whole ancestor chain: a symlink partway
        // down could otherwise sidestep the checks below. `scanRoot` is
        // resolved the same way in `Context.init`, so containment stays
        // consistent.
        let resolved = standardized.resolvingSymlinksInPath()
        let resolvedPath = normalizedPathString(resolved)

        if forbiddenExactPaths.contains(resolvedPath) {
            return .refused(reason: "path is a protected system directory")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath()
        let parentPath = normalizedPathString(resolved.deletingLastPathComponent().standardizedFileURL)
        let leafName = resolved.lastPathComponent

        if resolvedPath == normalizedPathString(home) {
            return .refused(reason: "path is the home directory")
        }
        if parentPath == normalizedPathString(home), protectedHomeChildren.contains(leafName) {
            return .refused(reason: "path is a standard home directory")
        }

        // A chosen scan root can be any ancestor, including "/" — so another
        // user's home must be just as protected as the current user's.
        if parentPath == usersDirectoryPath {
            return .refused(reason: "path is a user's home directory")
        }
        let grandparentPath = normalizedPathString(
            resolved.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        )
        if grandparentPath == usersDirectoryPath, protectedHomeChildren.contains(leafName) {
            return .refused(reason: "path is another user's standard home directory")
        }

        if isVolumeRoot(resolvedPath) {
            return .refused(reason: "path is a volume root")
        }

        // Before `isRootOwned`, which cannot tell absence from unreadability
        // and reports both as root ownership. Deliberately after the
        // `/Users` rules, which are more specific about what a non-existent
        // path would have been — see
        // `nonExistentUsersChildIsRefusedAsAnotherUsersHomeDirectory`.
        if isAbsent(resolved) {
            return .refused(reason: doesNotExistReason)
        }

        if isRootOwned(resolved), ignoringRootOwnership == false {
            return .refused(reason: rootOwnedReason)
        }

        if context.declaredPaths.contains(resolvedPath) {
            return .allowed
        }

        let rootComponents = context.scanRoot.pathComponents
        let pathComponents = resolved.pathComponents

        // The scan root itself is never a candidate. Kept unconditional
        // (not folded into the `isPlainDirectory` branch below) so a scan
        // root that is a package or a file can't evaluate as allowed
        // against itself.
        guard pathComponents.count > rootComponents.count else {
            return .refused(reason: "path is not at least two levels below the scan root")
        }
        // Scoped to plain directories only: guards shallow, high-blast-radius
        // directories like ~/Documents or a project root. A file or package
        // one level down is no more dangerous than one two levels down, and
        // applying depth to those understates what's on disk. ~/Documents
        // itself is protected by `protectedHomeChildren`, not by depth.
        if isPlainDirectory(resolved) {
            guard pathComponents.count >= rootComponents.count + 2 else {
                return .refused(reason: "path is not at least two levels below the scan root")
            }
        }
        guard Array(pathComponents.prefix(rootComponents.count)) == rootComponents else {
            return .refused(reason: "path is outside the scan root")
        }

        return .allowed
    }

    // MARK: - Probes

    /// `URL.path(percentEncoded:)` preserves a trailing "/" for
    /// directory-hinted URLs, while the legacy `.path` property (used to
    /// build `declaredPaths`) strips it. Every path-string comparison in
    /// `evaluate` goes through this so the mismatch can never defeat a rule.
    ///
    /// Do not delete the strip as dead code after testing only paths that
    /// exist: for an existing path, `resolvingSymlinksInPath()` already
    /// reconciles spellings before this runs, but for a non-existent path
    /// there's nothing on disk to consult, so a directory-hinted and a plain
    /// spelling of the same missing path diverge unless this strip
    /// reconciles them. Pinned, using non-existent paths so the filesystem
    /// can't paper over a broken strip, by `nonExistentDeclaredPathContextAgreesRegardlessOfSpelling`,
    /// `nonExistentDeclaredPathWithParentTraversalAndTrailingSlashAgrees`,
    /// and `nonExistentUsersChildIsRefusedAsAnotherUsersHomeDirectory` in
    /// `PathGuardTests.swift`.
    ///
    /// Intentionally duplicates `Candidate.normalizedPathKey(for:)` rather
    /// than depending on it — `PathGuard` is the safety backstop and should
    /// not take a dependency on `Models` for four lines of string logic. The
    /// same three tests pin that the two stay in agreement.
    private static func normalizedPathString(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink ?? false
    }

    /// True for a directory macOS does not present as a single object.
    ///
    /// Fail-safe direction is `true`: when the attributes cannot be read, the
    /// path is treated as a plain directory and therefore still subject to
    /// the depth rule. A path that does not exist never reaches here anyway —
    /// `isRootOwned` refuses it first, fail-closed.
    private static func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              let isDirectory = values.isDirectory
        else { return true }
        guard isDirectory else { return false }
        return values.isPackage != true
    }

    /// `path == "/"` is not handled here — `forbiddenExactPaths` already
    /// refuses it, before this runs.
    private static func isVolumeRoot(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 2 && components[0] == "Volumes"
    }

    /// True only when the path is genuinely not on disk — never merely
    /// because this process cannot see it.
    ///
    /// `fileExists` answers false for both, and they are opposite facts: an
    /// absent path is a phantom whose disclosure would overstate what an app
    /// owns, while an unreadable one is a real gap that must keep being
    /// disclosed. The nearest *existing* ancestor is what discriminates
    /// them, and the walk is what makes it work in the case that prompted
    /// this: `~/Library/Caches/BraveSoftware/Brave-Browser` was absent
    /// because `BraveSoftware` was absent too, so the immediate parent could
    /// answer no better than the path itself.
    ///
    /// Fail-safe direction is `false` — "cannot tell" falls through to
    /// `isRootOwned`, which refuses. A wrong answer here therefore keeps a
    /// path disclosed that might have been dropped; it can never drop one
    /// that should have been disclosed, and it can never make anything
    /// deletable, since both branches end in a refusal either way.
    private static func isAbsent(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path(percentEncoded: false)) else { return false }

        var ancestor = url.deletingLastPathComponent()
        while ancestor.pathComponents.count > 1 {
            let path = ancestor.path(percentEncoded: false)
            if manager.fileExists(atPath: path) {
                // The ancestor exists, so it is the one that can answer. If
                // we may read it, nothing is hiding in it and the path is
                // genuinely gone.
                return manager.isReadableFile(atPath: path)
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return false
    }

    private static func isRootOwned(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        ) else {
            // Cannot read ownership — refuse rather than assume.
            return true
        }
        guard let ownerID = attributes[.ownerAccountID] as? NSNumber else { return true }
        return ownerID.intValue == 0
    }
}
