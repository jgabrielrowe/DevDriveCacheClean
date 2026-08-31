// Tests/DDCCCoreTests/DiscoveryTests.swift
import Testing
import Foundation
@testable import DDCCCore

@Test func absolutePathPatternYieldsOneExplicitCandidate() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("Caches/Homebrew/downloads/pkg.tar", byteCount: 1024)
        let profile = ScanProfile(category: .homebrew, patterns: [
            .path("~/Caches/Homebrew", tier: .costly),
        ])

        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates

        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.path.lastPathComponent == "Homebrew")
        #expect(candidate.tier == .costly)
        #expect(candidate.specificity == .explicit)
        #expect(candidate.removability == .removable)
    }
}

@Test func absolutePathPatternSkipsMissingPaths() async throws {
    try await withTempDirectory { root in
        let profile = ScanProfile(category: .homebrew, patterns: [
            .path("~/Caches/DoesNotExist", tier: .costly),
        ])
        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates
        #expect(candidates.isEmpty)
    }
}

@Test func absolutePathPatternCarriesRemovability() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Locked")
        let profile = ScanProfile(category: .systemCaches, patterns: [
            .path("~/Locked", tier: .costly, removability: .requiresPrivileges),
        ])
        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates
        #expect(candidates.first?.removability == .requiresPrivileges)
    }
}

@Test func subdirectoriesPatternYieldsOneEnumeratedCandidatePerChild() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Caches/com.example.one")
        try tree.directory("Caches/com.example.two")
        try tree.file("Caches/loose-file.txt", byteCount: 16)
        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", tier: .safe),
        ])

        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates

        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.specificity == .enumerated })
        #expect(Set(candidates.map(\.path.lastPathComponent))
            == ["com.example.one", "com.example.two"])
    }
}

@Test func subdirectoriesPatternSkipsMissingParent() async throws {
    try await withTempDirectory { root in
        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/NoSuchParent", tier: .safe),
        ])
        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates
        #expect(candidates.isEmpty)
    }
}

/// Containers hold user documents. childSubpath must reach the cache inside
/// each container and never emit the container itself.
@Test func childSubpathReachesInsideEachChildWithoutEmittingTheChild() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file(
            "Containers/com.example.app/Data/Library/Caches/blob.bin", byteCount: 2048)
        try tree.file(
            "Containers/com.example.app/Data/Documents/important.txt", byteCount: 64)
        try tree.directory("Containers/com.example.nocache/Data")

        let profile = ScanProfile(category: .appCaches, patterns: [
            .childPath(in: "~/Containers", subpath: "Data/Library/Caches", tier: .safe),
        ])
        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates

        #expect(candidates.count == 1)
        let path = try #require(candidates.first?.path.path(percentEncoded: false))
        #expect(path.hasSuffix("com.example.app/Data/Library/Caches"))
        #expect(path.contains("Documents") == false)
    }
}

@Test func discoveryIgnoresDirectoryNameKind() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("project/node_modules")
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates
        #expect(candidates.isEmpty)
    }
}

@Test func displayNamePrefixesTheCategory() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Caches/Homebrew")
        let profile = ScanProfile(category: .homebrew, patterns: [
            .path("~/Caches/Homebrew", tier: .costly),
        ])
        let scanner = FileScanner()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates
        #expect(candidates.first?.displayName == "Homebrew: Homebrew")
    }
}

@Test func cancellationStopsDiscovery() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<50 { try tree.directory("Caches/dir-\(index)") }
        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", tier: .safe),
        ])
        let scanner = FileScanner()
        await scanner.cancel()
        let candidates = await scanner.discoverPathPatterns(profiles: [profile], home: root).candidates
        #expect(candidates.isEmpty)
    }
}

/// Site 1 of 4. An `.absolutePath` pattern whose target exists but cannot be
/// stat'ed must not be skipped with nothing recorded. Collapsing the probe to
/// a `Bool` via `try?` returns the same `false` for "refused" as for "not
/// there", and the candidate — with every byte under it — then vanishes from
/// a scan that reports itself exact.
@Test func anAbsolutePathThatCannotBeReadIsCounted() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Vault/Secret")
        let vault = root.appending(path: "Vault", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: vault.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: vault.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .appCaches, patterns: [
            .path("~/Vault/Secret", tier: .safe),
        ])
        let report = await FileScanner().discoverPathPatterns(profiles: [profile], home: root)

        #expect(report.candidates.isEmpty)
        #expect(report.refusals.count == 1)
    }
}

/// The rule that keeps the caveat meaningful. Most profile paths do not exist
/// on any given machine; if absence counted, every scan everywhere would report
/// dozens of unreadable folders and users would learn to ignore the warning.
@Test func anAbsolutePathThatSimplyDoesNotExistIsNotCounted() async throws {
    try await withTempDirectory { root in
        let profile = ScanProfile(category: .appCaches, patterns: [
            .path("~/Caches/DoesNotExist", tier: .costly),
        ])
        let report = await FileScanner().discoverPathPatterns(profiles: [profile], home: root)

        #expect(report.candidates.isEmpty)
        #expect(report.refusals.count == 0)
    }
}

/// Site 2 of 4. `childDirectories` returned `[]` on refusal, so every child of
/// an unreadable enumeration parent vanished at once — the largest single
/// silent loss in the engine, since `.subdirs` parents like
/// `~/Library/Application Support` hold whole categories.
@Test func aSubdirectoriesParentThatCannotBeListedIsCounted() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("Caches/com.example.one")
        try tree.directory("Caches/com.example.two")
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: caches.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: caches.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/Caches", tier: .safe),
        ])
        let report = await FileScanner().discoverPathPatterns(profiles: [profile], home: root)

        #expect(report.candidates.isEmpty)
        #expect(report.refusals.count == 1)
    }
}

/// The companion for site 2: a `.subdirs` parent that is simply not present is
/// the overwhelmingly common case and must stay silent.
@Test func aSubdirectoriesParentThatDoesNotExistIsNotCounted() async throws {
    try await withTempDirectory { root in
        let profile = ScanProfile(category: .appCaches, patterns: [
            .subdirs(of: "~/NotHere", tier: .safe),
        ])
        let report = await FileScanner().discoverPathPatterns(profiles: [profile], home: root)

        #expect(report.candidates.isEmpty)
        #expect(report.refusals.count == 0)
    }
}
