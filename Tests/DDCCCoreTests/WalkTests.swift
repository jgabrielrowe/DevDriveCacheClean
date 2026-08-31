import Testing
import Foundation
@testable import DDCCCore

private func walk(
    _ root: URL, _ profiles: [ScanProfile], scanner: FileScanner = FileScanner()
) async -> WalkReport {
    await scanner.walk(root: root, profiles: profiles, onProgress: { _ in })
}

@Test func unmarkedDirectoryNameMatches() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/node_modules/pkg/index.js", byteCount: 512)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let result = await walk(root, [profile])
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.path.lastPathComponent == "node_modules")
        #expect(result.outcome == .finished)
    }
}

@Test func siblingMarkerGatesTheMatch() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("rust-project/target")
        try tree.file("rust-project/Cargo.toml")
        try tree.directory("not-rust/target")

        let profile = ScanProfile(category: .rust, patterns: [
            .dir("target", marker: .sibling("Cargo.toml"), tier: .safe),
        ])
        let result = await walk(root, [profile])

        #expect(result.candidates.count == 1)
        let path = try #require(result.candidates.first?.path.path(percentEncoded: false))
        #expect(path.contains("rust-project"))
    }
}

/// The regression this plan exists to fix: pyvenv.cfg lives inside the
/// virtualenv, so the old sibling check meant non-dot venv/ never matched.
@Test func childMarkerMatchesVenv() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/venv/pyvenv.cfg")
        try tree.file("project/venv/lib/site.py", byteCount: 256)

        let profile = ScanProfile(category: .python, patterns: [
            .dir("venv", marker: .child("pyvenv.cfg"), tier: .safe),
        ])
        let result = await walk(root, [profile])

        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.path.lastPathComponent == "venv")
    }
}

@Test func bareVenvWithoutMarkerFileIsNotMatched() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/venv/notes.txt", byteCount: 16)
        let profile = ScanProfile(category: .python, patterns: [
            .dir("venv", marker: .child("pyvenv.cfg"), tier: .safe),
        ])
        let result = await walk(root, [profile])
        #expect(result.candidates.isEmpty)
    }
}

@Test func siblingAnyMarkerMatchesEitherBuildFile() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("kotlin/build")
        try tree.file("kotlin/build.gradle.kts")
        let profile = ScanProfile(category: .javaKotlin, patterns: [
            .dir("build", marker: .siblingAny(["build.gradle", "build.gradle.kts"]), tier: .safe),
        ])
        let result = await walk(root, [profile])
        #expect(result.candidates.count == 1)
    }
}

@Test func nestedMatchesOfTheSamePatternYieldOnlyTheOutermost() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/node_modules/a/node_modules/b/index.js", byteCount: 128)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let result = await walk(root, [profile])
        #expect(result.candidates.count == 1)
    }
}

@Test func hiddenDirectoriesAreTraversed() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/.venv/lib/site.py", byteCount: 256)
        let profile = ScanProfile(category: .python, patterns: [
            .dir(".venv", tier: .safe),
        ])
        let result = await walk(root, [profile])
        #expect(result.candidates.count == 1)
    }
}

@Test func skippedDirectoriesAreNotDescendedInto() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/.git/modules/node_modules/x.js", byteCount: 64)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let result = await walk(root, [profile])
        #expect(result.candidates.isEmpty)
    }
}

@Test func candidatesCarryPatternTierAndExplicitlyNotEnumerated() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("project/node_modules")
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let result = await walk(root, [profile])
        let candidate = try #require(result.candidates.first)
        #expect(candidate.tier == .safe)
        #expect(candidate.specificity == .explicit)
        #expect(candidate.removability == .removable)
    }
}

@Test func cancelledWalkReportsCancelledOutcome() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<30 { try tree.directory("project-\(index)/node_modules") }
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let scanner = FileScanner()
        await scanner.cancel()
        let result = await walk(root, [profile], scanner: scanner)
        #expect(result.outcome == .cancelled)
    }
}

@Test func progressIsReportedAtLeastOnce() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.directory("project/node_modules")
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])

        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let scanner = FileScanner()
        _ = await scanner.walk(root: root, profiles: [profile], onProgress: { _ in
            box.count += 1
        })
        #expect(box.count > 0)
    }
}

/// Site 3 of 4. The walk's enumerator was built with
/// `errorHandler: { _, _ in true }` — both the URL and the error discarded —
/// so a directory the walk is refused would leave no trace at all.
/// `FileFinder` counts its equivalent in `unreadableDirectoryCount`.
@Test func aDirectoryTheWalkCannotEnterIsCounted() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("open/project/node_modules/pkg/index.js", byteCount: 512)
        let sealed = try tree.directory("sealed")
        try tree.file("sealed/project/node_modules/pkg/index.js", byteCount: 512)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sealed.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let report = await FileScanner().walk(
            root: root, profiles: [profile], onProgress: { _ in })

        // The readable half still produces its candidate — a refusal must cost
        // only what it actually hid.
        #expect(report.candidates.count == 1)
        #expect(report.refusals.count > 0)
    }
}

/// Site 4 of 4. When the walk ROOT itself is unreadable, `walk` returned a
/// clean, complete, empty answer for a tree it never saw.
///
/// Measured: `FileManager.enumerator(at:)` on a `chmod 000`
/// directory returns a **non-nil** enumerator that yields nothing and fires the
/// error handler once. So this test exercises the error-handler path, not the
/// `guard let enumerator … else` branch. That branch is still fixed below, as
/// defence, but it is reachable only by inspection — say so, and do not claim
/// this test covers it.
@Test func aWalkRootThatCannotBeReadIsCounted() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let sealed = try tree.directory("sealed")
        try tree.file("sealed/project/node_modules/pkg/index.js", byteCount: 512)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sealed.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed.path(percentEncoded: false))
        }

        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let report = await FileScanner().walk(
            root: sealed, profiles: [profile], onProgress: { _ in })

        #expect(report.candidates.isEmpty)
        #expect(report.refusals.count > 0)
    }
}

/// A clean walk must report nothing unreadable, or the caveat fires on every
/// ordinary scan.
@Test func aCleanWalkReportsNothingUnreadable() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("project/node_modules/pkg/index.js", byteCount: 512)
        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
        ])
        let report = await FileScanner().walk(
            root: root, profiles: [profile], onProgress: { _ in })

        #expect(report.candidates.count == 1)
        #expect(report.refusals.count == 0)
    }
}

// MARK: - Overriding the traversal skip
//
// `Library` is in FileScanner.skipDirectories so the walk never descends into
// ~/Library, which the Caches view owns. But a Unity project's 2 GB import
// cache is also called Library, and with the skip checked before patterns it
// was unreachable at any tier. A marker-gated pattern may now name a skipped
// directory; an unmarked one still may not, and nothing descends either way.

@Test func markerGatedPatternReachesASkippedDirectoryName() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("MyGame/Library/Artifacts/db", byteCount: 512)
        try tree.directory("MyGame/Assets")
        try tree.directory("MyGame/ProjectSettings")

        let profile = ScanProfile(category: .genericBuild, patterns: [
            .dir("Library", marker: .siblingAll(["Assets", "ProjectSettings"]), tier: .safe),
        ])
        let result = await walk(root, [profile])

        #expect(result.candidates.count == 1)
        let path = try #require(result.candidates.first?.path.path(percentEncoded: false))
        #expect(path.hasSuffix("MyGame/Library"))
    }
}

/// The protection that makes the override safe. An unmarked pattern on a
/// skipped name would match ~/Library itself on a real machine, so a pattern
/// that offers no proof of what it found is refused outright.
@Test func unmarkedPatternNeverReachesASkippedDirectoryName() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("home/Library/Preferences/some.plist", byteCount: 512)

        let profile = ScanProfile(category: .genericBuild, patterns: [
            .dir("Library", tier: .safe),
        ])
        let result = await walk(root, [profile])

        #expect(result.candidates.isEmpty)
    }
}

/// A marker that does not match leaves the skip exactly as it was. This is the
/// shape of a real home directory: a Library with no project beside it.
@Test func aSkippedNameWithAFailingMarkerIsStillSkipped() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("home/Library/Preferences/some.plist", byteCount: 512)
        try tree.directory("home/Documents")

        let profile = ScanProfile(category: .genericBuild, patterns: [
            .dir("Library", marker: .siblingAll(["Assets", "ProjectSettings"]), tier: .safe),
        ])
        let result = await walk(root, [profile])

        #expect(result.candidates.isEmpty)
    }
}

/// The property the skip exists for, which the override must not weaken: the
/// interior of a skipped directory is never walked, matched or not. Without
/// this, ~/Library/Caches would be re-reported by the walk as well as by the
/// Caches view that owns it.
@Test func theInteriorOfASkippedDirectoryIsNeverWalked() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("home/Library/Caches/node_modules/pkg/index.js", byteCount: 512)
        try tree.directory("home/Assets")
        try tree.directory("home/ProjectSettings")

        let profile = ScanProfile(category: .nodeJS, patterns: [
            .dir("node_modules", tier: .safe),
            .dir("Library", marker: .siblingAll(["Assets", "ProjectSettings"]), tier: .safe),
        ])
        let result = await walk(root, [profile])

        // Library itself matches here, but the node_modules buried inside it
        // must not appear as a second candidate.
        let names = result.candidates.map(\.path.lastPathComponent)
        #expect(names == ["Library"])
    }
}
