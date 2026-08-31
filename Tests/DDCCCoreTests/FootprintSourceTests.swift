import Testing
import Foundation
@testable import DDCCCore

/// The Apple refusal by prefix is insufficient.
/// group.com.apple.* and groups.com.apple.* account for 181 entries and
/// 18.2 MB that a bare "com.apple." test misses, and they were the largest
/// apparent leftover group on the development machine.
@Test func appleGroupPrefixesAreRefusedAlongsideComApple() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try tree.file("Library/Containers/com.apple.something/marker", byteCount: 4)
        try tree.file("Library/Group Containers/group.com.apple.family/marker", byteCount: 4)
        try tree.file("Library/Group Containers/groups.com.apple.somefeature/marker", byteCount: 4)
        try tree.file("Library/Group Containers/com.example.nonapple/marker", byteCount: 4)

        let env = ScanEnvironment(libraryURL: library)
        let source = ContainerSource()

        let bareApple = BundleIdentity(
            bundleID: "com.apple.something", displayName: "Something", bundleURL: nil, isPresent: true)
        #expect(source.evidence(for: bareApple, in: env).isEmpty)

        let groupApple = BundleIdentity(
            bundleID: "group.com.apple.family", displayName: "Family", bundleURL: nil, isPresent: true)
        #expect(source.evidence(for: groupApple, in: env).isEmpty)

        let groupsApple = BundleIdentity(
            bundleID: "groups.com.apple.somefeature", displayName: "SomeFeature", bundleURL: nil, isPresent: true)
        #expect(source.evidence(for: groupsApple, in: env).isEmpty)

        // Positive control: a non-Apple identity with the identical shape of
        // match still gets its evidence. The refusal targets Apple's
        // namespace specifically, not group-container matching in general.
        let nonApple = BundleIdentity(
            bundleID: "com.example.nonapple", displayName: "Example", bundleURL: nil, isPresent: true)
        let nonAppleEvidence = source.evidence(for: nonApple, in: env)
        #expect(nonAppleEvidence.count == 1)
        #expect(nonAppleEvidence.first?.source == .groupContainer)
    }
}

/// Messaging-host roots are DISCOVERED by directory name, so there is no
/// browser list to maintain and no browser missed when a new one ships.
/// Measured: 12 profile directories across 9 browsers on this machine.
@Test func messagingHostRootsAreFoundByNameNotByABrowserList() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let targetURL = appURL.appendingPathComponent("Contents/Helpers/host", isDirectory: false)
        try tree.file("Applications/Example.app/Contents/Helpers/host", byteCount: 1)

        let manifest = """
            {"name": "com.example.host", "path": "\(targetURL.path)", "type": "stdio"}
            """

        // Four browser roots, none of them a hardcoded three-item list could
        // cover: one shallow, one with a channel subdirectory, one nested
        // under a profile (the deepest real shape measured), and one whose
        // vendor name would appear on no maintained browser list at all.
        try tree.file("Library/Application Support/Vivaldi/NativeMessagingHosts/com.example.host.json")
        try (manifest.data(using: .utf8)!).write(to:
            root.appendingPathComponent("Library/Application Support/Vivaldi/NativeMessagingHosts/com.example.host.json"))

        for relativeDir in [
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Library/Application Support/Google/Chrome/Profile 2/NativeMessagingHosts",
            "Library/Application Support/FifthBrowser/NativeMessagingHosts",
        ] {
            try tree.directory(relativeDir)
            try manifest.data(using: .utf8)!.write(
                to: root.appendingPathComponent("\(relativeDir)/com.example.host.json"))
        }

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.app", displayName: "Example", bundleURL: appURL, isPresent: true)

        let evidence = MessagingHostSource().evidence(for: identity, in: env)
        #expect(evidence.count == 4)
        #expect(evidence.allSatisfy { $0.source == .messagingHost })
    }
}

/// Name matching must NOT be attempted for messaging hosts. Claude.app is
/// com.anthropic.claudefordesktop against a manifest named
/// com.anthropic.claude_code_browser_extension; neither is a dotted
/// descendant of the other, and matching on the vendor component would
/// sweep com.google.*. Attribution comes from the declared target only.
@Test func aMessagingHostIsNotAttributedByNameSimilarity() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let claudeAppURL = root.appendingPathComponent("Applications/Claude.app", isDirectory: true)

        // Highly name-similar to the bundle id, but declares a target
        // OUTSIDE Claude.app's own bundle (mirrors the real
        // com.anthropic.claude_code_browser_extension manifest, which
        // belongs to the unrelated Claude Code CLI, not the desktop app).
        let outsideTarget = root.appendingPathComponent(".claude/chrome/chrome-native-host", isDirectory: false)
        try tree.file(".claude/chrome/chrome-native-host", byteCount: 1)
        let nameSimilarManifest = """
            {"name": "com.anthropic.claude_code_browser_extension", "path": "\(outsideTarget.path)"}
            """
        try tree.directory("Library/Application Support/SomeBrowser/NativeMessagingHosts")
        try nameSimilarManifest.data(using: .utf8)!.write(to:
            root.appendingPathComponent("Library/Application Support/SomeBrowser/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json"))

        // No name resemblance to the bundle id at all, but declares a
        // target genuinely inside Claude.app's own bundle (mirrors the
        // real com.anthropic.claude_browser_extension manifest).
        let insideTarget = claudeAppURL.appendingPathComponent("Contents/Helpers/chrome-native-host", isDirectory: false)
        try tree.file("Applications/Claude.app/Contents/Helpers/chrome-native-host", byteCount: 1)
        let unrelatedNameManifest = """
            {"name": "com.totallyunrelated.vendor", "path": "\(insideTarget.path)"}
            """
        try unrelatedNameManifest.data(using: .utf8)!.write(to:
            root.appendingPathComponent("Library/Application Support/SomeBrowser/NativeMessagingHosts/com.totallyunrelated.vendor.json"))

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.anthropic.claudefordesktop", displayName: "Claude", bundleURL: claudeAppURL, isPresent: true)

        let evidence = MessagingHostSource().evidence(for: identity, in: env)
        #expect(evidence.count == 1)
        #expect(evidence.first?.path == Candidate.normalizedPathKey(for:
            root.appendingPathComponent("Library/Application Support/SomeBrowser/NativeMessagingHosts/com.totallyunrelated.vendor.json")))
    }
}

/// The shelf source matches exact bundle id only — no prefix, no fuzzy
/// match — accounting for the `.plist` / `.savedState` suffixes.
@Test func shelfEntriesAreMatchedByExactBundleIDOnly() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try tree.file("Library/Preferences/com.foo.bar.plist", byteCount: 2)
        // Decoy: a longer id that has the query id as a string prefix.
        // Exact matching must not treat this as a hit.
        try tree.file("Library/Preferences/com.foo.bar2.plist", byteCount: 2)
        try tree.file("Library/Caches/com.foo.bar/marker", byteCount: 2)
        try tree.file("Library/Saved Application State/com.foo.bar.savedState/marker", byteCount: 2)
        try tree.file("Library/HTTPStorages/com.foo.bar3/marker", byteCount: 2)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.foo.bar", displayName: "Bar", bundleURL: nil, isPresent: true)

        let evidence = ShelfSource().evidence(for: identity, in: env)
        #expect(evidence.count == 3)
        #expect(!evidence.contains { $0.path.contains("com.foo.bar2") })
        #expect(!evidence.contains { $0.path.contains("com.foo.bar3") })

        let sources = evidence.map(\.source)
        #expect(sources.contains(.shelf("Preferences")))
        #expect(sources.contains(.shelf("Caches")))
        #expect(sources.contains(.shelf("Saved Application State")))
    }
}

// MARK: - The walk is done once, not once per identity

/// `UninstallCoordinator` calls `assemble` once per identity — 100-150 times
/// on a real machine, against 5,579 directories here. Walking `Application
/// Support` to five levels and re-parsing every manifest inside
/// `MessagingHostSource.evidence` would repeat all of that per call; the
/// snapshot makes it one walk.
///
/// Pinned by removing the manifest from disk between building the snapshot
/// and asking the question: a source that still answers read the snapshot,
/// and a source that goes quiet re-walked. The default-constructed source
/// is asserted alongside it, so this distinguishes "snapshot consulted"
/// from "fixture never worked".
@Test func aSnapshottedMessagingHostSourceDoesNotRewalkPerIdentity() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let targetURL = appURL.appendingPathComponent("Contents/Helpers/host", isDirectory: false)
        try tree.file("Applications/Example.app/Contents/Helpers/host", byteCount: 1)

        let manifestURL = root.appendingPathComponent(
            "Library/Application Support/Vivaldi/NativeMessagingHosts/com.example.host.json")
        try tree.directory("Library/Application Support/Vivaldi/NativeMessagingHosts")
        try """
            {"name": "com.example.host", "path": "\(targetURL.path)", "type": "stdio"}
            """.data(using: .utf8)!.write(to: manifestURL)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.example.app", displayName: "Example", bundleURL: appURL, isPresent: true)

        let snapshot = MessagingHostSource.snapshot(under: env.applicationSupportURL)
        try FileManager.default.removeItem(at: manifestURL)

        #expect(MessagingHostSource(snapshot: snapshot).evidence(for: identity, in: env).count == 1)
        #expect(MessagingHostSource().evidence(for: identity, in: env).isEmpty)
    }
}

/// The snapshot is keyed to the `Application Support` it was read from. A
/// snapshot answering for a *different* environment would attribute one
/// tree's manifests to another tree's identities — a wrong attribution,
/// which is the direction this feature has no room to be wrong in — so a
/// mismatched snapshot is ignored and the source reads live instead.
@Test func aMessagingHostSnapshotFromAnotherLibraryIsIgnored() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let targetURL = appURL.appendingPathComponent("Contents/Helpers/host", isDirectory: false)
        try tree.file("Applications/Example.app/Contents/Helpers/host", byteCount: 1)

        // The manifest exists under LibraryA only.
        try tree.directory("LibraryA/Application Support/Vivaldi/NativeMessagingHosts")
        try tree.directory("LibraryB/Application Support")
        try """
            {"name": "com.example.host", "path": "\(targetURL.path)", "type": "stdio"}
            """.data(using: .utf8)!.write(to: root.appendingPathComponent(
                "LibraryA/Application Support/Vivaldi/NativeMessagingHosts/com.example.host.json"))

        let envA = ScanEnvironment(libraryURL: root.appendingPathComponent("LibraryA", isDirectory: true))
        let envB = ScanEnvironment(libraryURL: root.appendingPathComponent("LibraryB", isDirectory: true))
        let identity = BundleIdentity(
            bundleID: "com.example.app", displayName: "Example", bundleURL: appURL, isPresent: true)

        let snapshotA = MessagingHostSource.snapshot(under: envA.applicationSupportURL)
        #expect(MessagingHostSource(snapshot: snapshotA).evidence(for: identity, in: envA).count == 1)
        // Same snapshot, different environment: nothing borrowed.
        #expect(MessagingHostSource(snapshot: snapshotA).evidence(for: identity, in: envB).isEmpty)
    }
}

/// The same two properties for the shelf listings — five
/// `contentsOfDirectory` calls of roughly 580 entries each, per identity,
/// at smaller scale than the messaging-host walk but the same shape.
@Test func aSnapshottedShelfSourceReadsTheShelvesOnceAndOnlyItsOwnLibrary() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let plistURL = root.appendingPathComponent("LibraryA/Preferences/com.example.app.plist")
        try tree.file("LibraryA/Preferences/com.example.app.plist", byteCount: 64)
        try tree.directory("LibraryB/Preferences")

        let envA = ScanEnvironment(libraryURL: root.appendingPathComponent("LibraryA", isDirectory: true))
        let envB = ScanEnvironment(libraryURL: root.appendingPathComponent("LibraryB", isDirectory: true))
        let identity = BundleIdentity(
            bundleID: "com.example.app", displayName: "Example", bundleURL: nil, isPresent: true)

        let snapshotA = ShelfSource.snapshot(of: envA)
        try FileManager.default.removeItem(at: plistURL)

        // Read from the snapshot, not from the (now empty) disk.
        #expect(ShelfSource(snapshot: snapshotA).evidence(for: identity, in: envA).count == 1)
        #expect(ShelfSource().evidence(for: identity, in: envA).isEmpty)
        // And never borrowed by a different library.
        #expect(ShelfSource(snapshot: snapshotA).evidence(for: identity, in: envB).isEmpty)
    }
}

/// `Application Support` is a shelf like the other five: an entry named with
/// the exact bundle id belongs to that app, and one named after the product
/// does not belong to anyone this source can name.
///
/// It was left out when the shelves were first written because the directory
/// is dominated by product-named entries no rule can attribute — measured on
/// the development machine, 85 of 117 top-level entries, holding all but
/// 624 KB of 24.55 GB. Leaving it out entirely also discarded the 32 entries
/// that *are* bundle-id shaped, which the exact-match rule reads as safely
/// here as it does under `Preferences`. The product-named remainder stays
/// unattributed, which is the same answer as before.
@Test func applicationSupportIsMatchedByExactBundleIDLikeTheOtherShelves() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try tree.file("Library/Application Support/com.foo.bar/marker", byteCount: 2)
        // Decoy: the product-named shape that dominates this directory and
        // that no evidence source may claim. "Bar" is this identity's own
        // display name, so a source that reached for the display name would
        // take it.
        try tree.file("Library/Application Support/Bar/marker", byteCount: 2)
        // Decoy: a longer id carrying the query id as a string prefix.
        try tree.file("Library/Application Support/com.foo.bar2/marker", byteCount: 2)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.foo.bar", displayName: "Bar", bundleURL: nil, isPresent: true)

        let evidence = ShelfSource().evidence(for: identity, in: env)
        #expect(evidence.count == 1)
        #expect(evidence.first?.source == .shelf("Application Support"))
        #expect(evidence.first?.path == Candidate.normalizedPathKey(for:
            library.appendingPathComponent("Application Support/com.foo.bar", isDirectory: true)))
    }
}

/// `WebKit` and `Cookies` are bundle-id keyed like the other shelves.
/// Measured on the development machine: 16 `WebKit` entries, 14 of them
/// bundle-id shaped, 13.8 MB. `Cookies` was empty there, so its shape is
/// asserted from the naming convention (`<bundle id>.binarycookies`) rather
/// than from a local measurement.
@Test func webKitAndCookiesAreMatchedByExactBundleIDLikeTheOtherShelves() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = root.appendingPathComponent("Library", isDirectory: true)

        try tree.file("Library/WebKit/com.foo.bar/marker", byteCount: 2)
        try tree.file("Library/Cookies/com.foo.bar.binarycookies", byteCount: 2)
        // Decoys: a longer id carrying the query id as a string prefix.
        try tree.file("Library/WebKit/com.foo.bar2/marker", byteCount: 2)
        try tree.file("Library/Cookies/com.foo.bar2.binarycookies", byteCount: 2)

        let env = ScanEnvironment(libraryURL: library)
        let identity = BundleIdentity(
            bundleID: "com.foo.bar", displayName: "Bar", bundleURL: nil, isPresent: true)

        let evidence = ShelfSource().evidence(for: identity, in: env)
        let sources = evidence.map(\.source)
        #expect(sources.contains(.shelf("WebKit")))
        #expect(sources.contains(.shelf("Cookies")))
        #expect(!evidence.contains { $0.path.contains("com.foo.bar2") })
    }
}

/// The allowlist is what lets a cask-declared `WebKit` path survive to the
/// user. Edge's real stanza declares `~/Library/WebKit/com.microsoft.edgemac`
/// and DDCC discarded it purely because the root was not allowlisted, which
/// is a different failure from refusing it on evidence.
@Test func webKitAndCookiesAreAllowlistedRoots() throws {
    #expect(FootprintAssembler.allowlistedRootNames.contains("WebKit"))
    #expect(FootprintAssembler.allowlistedRootNames.contains("Cookies"))
}
