import Testing
import Foundation
@testable import DDCCCore

// Real strings from the development machine, not invented ones:
//   Godot templates   4.6.1.stable, 4.6.1.stable.mono
//   Godot app         4.7.2
//   Unreal engine     UE_5.8
//   Unity editor      6000.5.10f1

@Test func aVersionCoreIsTheLeadingNumericRun() {
    #expect(EngineVersions.numericCore(of: "4.6.1.stable") == "4.6.1")
    #expect(EngineVersions.numericCore(of: "4.6.1.stable.mono") == "4.6.1")
    #expect(EngineVersions.numericCore(of: "4.7.2") == "4.7.2")
}

/// Unreal names its directory `UE_5.8`, so the core cannot start at the first
/// character. Unity's `6000.5.10f1` ends mid-component, so it cannot stop at
/// the first non-numeric component either.
@Test func aVersionCoreSurvivesAPrefixAndATrailingSuffix() {
    #expect(EngineVersions.numericCore(of: "UE_5.8") == "5.8")
    #expect(EngineVersions.numericCore(of: "6000.5.10f1") == "6000.5.10")
}

@Test func somethingWithNoVersionInItHasNoCore() {
    #expect(EngineVersions.numericCore(of: "templates") == nil)
    #expect(EngineVersions.numericCore(of: "") == nil)
}

/// The measured case: 4.7.2 is installed and every template on disk is 4.6.1,
/// so 2.0 GB is dead weight.
@Test func aVersionWithNoInstalledEngineIsStale() {
    let dirs = ["4.6.1.stable", "4.6.1.stable.mono"].map {
        URL(fileURLWithPath: "/tmp/export_templates/\($0)", isDirectory: true)
    }
    let stale = EngineVersions.stale(among: dirs, retaining: ["4.7.2"])
    #expect(stale.count == 2)
}

/// The mono variant shares a core with the plain one, so installing 4.6.1
/// retains both. A rule matching whole directory names would have kept only one.
@Test func everyVariantOfAnInstalledVersionIsRetained() {
    let dirs = ["4.6.1.stable", "4.6.1.stable.mono"].map {
        URL(fileURLWithPath: "/tmp/export_templates/\($0)", isDirectory: true)
    }
    #expect(EngineVersions.stale(among: dirs, retaining: ["4.6.1"]).isEmpty)
}

/// Fail closed. A directory whose name carries no version is something this
/// rule does not understand, and offering it for deletion on the strength of
/// not understanding it is the one outcome that must never happen.
@Test func aDirectoryWithNoParseableVersionIsNeverOffered() {
    let dirs = [URL(fileURLWithPath: "/tmp/export_templates/scratch", isDirectory: true)]
    #expect(EngineVersions.stale(among: dirs, retaining: ["4.7.2"]).isEmpty)
}

/// And when nothing is installed at all, nothing is judged stale — an engine
/// that has been removed is the Uninstall view's business, not this rule's,
/// and an empty install list must not read as "everything is dead".
@Test func noInstalledVersionsMeansNothingIsOffered() {
    let dirs = [URL(fileURLWithPath: "/tmp/export_templates/4.6.1.stable", isDirectory: true)]
    #expect(EngineVersions.stale(among: dirs, retaining: []).isEmpty)
}

// MARK: - Finding what is installed
//
// Each engine answers "which versions are installed" from a different place,
// which is why this is a small curated enum rather than one rule. Godot writes
// a version into its bundle's Info.plist; Unreal and Unity each name a
// directory per version, in different roots.

@Test func godotVersionsComeFromTheBundlesOwnPlist() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let apps = try tree.directory("Applications")
        _ = try tree.directory("Applications/Godot.app/Contents")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>4.7.2</string>
        </dict></plist>
        """
        try plist.write(
            to: apps.appending(path: "Godot.app/Contents/Info.plist"),
            atomically: true, encoding: .utf8)
        // A neighbour that is not Godot must not contribute a version.
        _ = try tree.directory("Applications/Safari.app/Contents")

        #expect(EngineVersions.Engine.godot.installedVersions(searching: [apps]) == ["4.7.2"])
    }
}

@Test func unrealAndUnityVersionsComeFromDirectoryNames() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let epic = try tree.directory("Shared/Epic Games")
        _ = try tree.directory("Shared/Epic Games/UE_5.8")
        _ = try tree.directory("Shared/Epic Games/UE_5.7")
        #expect(EngineVersions.Engine.unreal.installedVersions(searching: [epic]) == ["UE_5.8", "UE_5.7"])

        let editors = try tree.directory("Applications/Unity/Hub/Editor")
        _ = try tree.directory("Applications/Unity/Hub/Editor/6000.5.10f1")
        #expect(EngineVersions.Engine.unity.installedVersions(searching: [editors]) == ["6000.5.10f1"])
    }
}

/// A root that does not exist is simply no versions, not an error — and it must
/// not read as "nothing installed, so everything is stale", which `stale`
/// already refuses independently.
@Test func aMissingRootContributesNoVersions() {
    let absent = [URL(fileURLWithPath: "/nonexistent/engines")]
    for engine in EngineVersions.Engine.allCases {
        #expect(engine.installedVersions(searching: absent).isEmpty, "\(engine)")
    }
}

// MARK: - Unity editors
//
// Unity is the one engine whose version directories ARE the installs, so
// "installed" cannot be the retention rule -- every version would retain
// itself and nothing would ever be offered. What makes an editor stale is
// that nothing needs it.
//
// A Unity project pins its editor in ProjectSettings/ProjectVersion.txt and
// will not open under another, so deleting a pinned editor breaks the project
// until a 17 GB re-download. The Hub records the pin per project in
// projects-v1.json, which is what makes this answerable rather than a guess.

private func hubRegistry(_ json: String, in root: URL) throws -> URL {
    let url = root.appending(path: "projects-v1.json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func aPinnedEditorIsRetainedEvenWhenItIsNotTheNewest() throws {
    try withTempDirectory { root in
        let registry = try hubRegistry("""
        {"schema_version":"v1","data":{
          "/Users/x/Old Project":{"title":"Old","version":"6000.5.6f1"}
        }}
        """, in: root)
        let retained = EngineVersions.Engine.unity.retainedEditorVersions(
            among: ["6000.5.6f1", "6000.5.10f1"], registry: registry)

        #expect(retained.contains("6000.5.6"))   // pinned by a project
        #expect(retained.contains("6000.5.10"))  // and the newest is always kept
    }
}

/// With nothing pinning it, an older editor is dead weight — which is the whole
/// case for listing them.
@Test func anOlderEditorNothingPinsIsOffered() throws {
    try withTempDirectory { root in
        let registry = try hubRegistry("""
        {"schema_version":"v1","data":{
          "/Users/x/Current":{"title":"Current","version":"6000.5.10f1"}
        }}
        """, in: root)
        let editors = ["6000.5.6f1", "6000.5.10f1"].map {
            URL(fileURLWithPath: "/Applications/Unity/Hub/Editor/\($0)", isDirectory: true)
        }
        let retained = EngineVersions.Engine.unity.retainedEditorVersions(
            among: editors.map(\.lastPathComponent), registry: registry)
        let stale = EngineVersions.stale(among: editors, retaining: retained)

        #expect(stale.map(\.lastPathComponent) == ["6000.5.6f1"])
    }
}

/// The newest is never offered, even with no projects at all. It is the one a
/// fresh install would give you back, and the Uninstall view is where a
/// current editor is removed.
@Test func theNewestEditorIsNeverOffered() throws {
    try withTempDirectory { root in
        let registry = try hubRegistry("""
        {"schema_version":"v1","data":{}}
        """, in: root)
        let editors = ["6000.5.10f1"].map {
            URL(fileURLWithPath: "/Applications/Unity/Hub/Editor/\($0)", isDirectory: true)
        }
        let retained = EngineVersions.Engine.unity.retainedEditorVersions(
            among: editors.map(\.lastPathComponent), registry: registry)
        #expect(EngineVersions.stale(among: editors, retaining: retained).isEmpty)
    }
}

/// Fail closed, hard. If the registry cannot be read or parsed, this rule
/// cannot know what any project needs, and an unreadable file must never read
/// as "no project needs anything".
@Test func anUnreadableRegistryRetainsEveryEditor() {
    let absent = URL(fileURLWithPath: "/nonexistent/projects-v1.json")
    let versions = ["6000.5.6f1", "6000.5.10f1"]
    let retained = EngineVersions.Engine.unity.retainedEditorVersions(
        among: versions, registry: absent)
    for v in versions {
        #expect(retained.contains(EngineVersions.numericCore(of: v) ?? "") , "\(v)")
    }
}
