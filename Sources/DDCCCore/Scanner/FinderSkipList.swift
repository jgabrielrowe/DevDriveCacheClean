// Sources/DDCCCore/Scanner/FinderSkipList.swift
import Foundation

/// Directories the Files view never descends into.
///
/// Three sources, unioned, all derived rather than hand-written:
///
/// 1. `FileScanner.skipDirectories` — `.git`, `.Trash`, `Library` and the
///    Spotlight internals the pattern walk already avoids.
/// 2. `ScanProfile.declaredDirectoryNames` — `node_modules`, `.venv`,
///    `target`, `.build`, `Pods` and the rest.
/// 3. `ScanProfile.declaredAbsolutePaths`, as a prefix check.
/// 4. `ScanProfile.declaredToolchainRoots`, also as a prefix check. Added
/// with the toolchain sweep: `~/.nvm/versions/node` sits outside
///    `~/Library`, so without this the finder walks into ~3.6 GB of node
///    versions and reports as anonymous large directories exactly the bytes
///    the Caches view now names.
///
/// The third is the one most easily missed: several package caches
/// (`~/.npm/_cacache`, `~/.cargo/registry`, `~/.m2/repository`, `~/.gem`,
/// `~/.nuget/packages`, `~/.bun/install/cache`, `~/.cache/uv`) live outside
/// `~/Library`, so skipping Library alone would leave the finder re-reporting
/// them as anonymous large directories.
///
/// Measured: home holds 2,073,009 files; these exclusions bring
/// traversal down to 655,395 — 68% of the tree removed before any per-entry
/// work happens.
public struct FinderSkipList: Sendable {
    private let names: Set<String>
    private let pathPrefixes: [String]

    public init(declaredPaths: Set<String>) {
        self.names = FileScanner.skipDirectories.union(ScanProfile.declaredDirectoryNames)
        // Stored with a trailing separator so a prefix test cannot match a
        // sibling that merely shares an opening substring: without it,
        // "~/.cargo/registry2" starts with "~/.cargo/registry" and would be
        // skipped. The exact path is compared separately.
        self.pathPrefixes = declaredPaths.union(ScanProfile.declaredToolchainRoots)
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    public func skipsDirectory(named name: String) -> Bool {
        names.contains(name)
    }

    public func skipsPath(_ url: URL) -> Bool {
        let key = Candidate.normalizedPathKey(for: url)
        if pathPrefixes.contains(where: { $0 == key + "/" }) { return true }
        return pathPrefixes.contains { key.hasPrefix($0) }
    }
}
