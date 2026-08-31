import Testing
import Foundation
@testable import DDCCCore

@Test func siblingMarkerMatchesFileBesideDirectory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("project/target")
        try tree.file("project/Cargo.toml")
        #expect(ScanProfile.Pattern.Marker.sibling("Cargo.toml").matches(directory: target))
    }
}

@Test func siblingMarkerRejectsWhenFileAbsent() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("project/target")
        #expect(ScanProfile.Pattern.Marker.sibling("Cargo.toml").matches(directory: target) == false)
    }
}

@Test func siblingMarkerDoesNotMatchFileInsideDirectory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("project/target")
        try tree.file("project/target/Cargo.toml")
        #expect(ScanProfile.Pattern.Marker.sibling("Cargo.toml").matches(directory: target) == false)
    }
}

@Test func siblingAnyMatchesWhenAnyCandidateExists() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let build = try tree.directory("project/build")
        try tree.file("project/build.gradle.kts")
        let marker = ScanProfile.Pattern.Marker.siblingAny(["build.gradle", "build.gradle.kts"])
        #expect(marker.matches(directory: build))
    }
}

@Test func siblingAnyRejectsWhenNoCandidateExists() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let build = try tree.directory("project/build")
        let marker = ScanProfile.Pattern.Marker.siblingAny(["build.gradle", "build.gradle.kts"])
        #expect(marker.matches(directory: build) == false)
    }
}

/// The bug this marker exists to fix: pyvenv.cfg lives inside a virtualenv,
/// so a sibling check never matches and non-dot `venv/` was never found.
@Test func childMarkerMatchesFileInsideDirectory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let venv = try tree.directory("project/venv")
        try tree.file("project/venv/pyvenv.cfg")
        #expect(ScanProfile.Pattern.Marker.child("pyvenv.cfg").matches(directory: venv))
    }
}

@Test func childMarkerDoesNotMatchSibling() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let venv = try tree.directory("project/venv")
        try tree.file("project/pyvenv.cfg")
        #expect(ScanProfile.Pattern.Marker.child("pyvenv.cfg").matches(directory: venv) == false)
    }
}

@Test func factoryCarriesTierAndDefaultsToRemovable() {
    let pattern = ScanProfile.Pattern.dir("node_modules", tier: .safe)
    #expect(pattern.tier == .safe)
    #expect(pattern.removability == .removable)
}

@Test func pathFactoryAcceptsExplicitRemovability() {
    let pattern = ScanProfile.Pattern.path(
        "/Library/Caches", tier: .costly, removability: .requiresPrivileges)
    #expect(pattern.removability == .requiresPrivileges)
}

// MARK: - siblingWithExtension
//
// An Unreal project is identified by a `.uproject` file whose name is the
// project's, so no fixed filename can find one. The existing markers all
// compare a name they were given; this one compares an extension across
// whatever the parent happens to hold.

@Test func siblingWithExtensionMatchesWhateverTheProjectIsCalled() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let intermediate = try tree.directory("MyProject/Intermediate")
        try tree.file("MyProject/MyProject.uproject")
        #expect(ScanProfile.Pattern.Marker.siblingWithExtension("uproject")
            .matches(directory: intermediate))
    }
}

@Test func siblingWithExtensionRejectsWhenNoSiblingCarriesIt() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let intermediate = try tree.directory("NotAProject/Intermediate")
        try tree.file("NotAProject/README.md")
        #expect(ScanProfile.Pattern.Marker.siblingWithExtension("uproject")
            .matches(directory: intermediate) == false)
    }
}

/// The same trap `siblingMarkerDoesNotMatchFileInsideDirectory` guards: a
/// `.uproject` *inside* Intermediate would not make Intermediate disposable.
@Test func siblingWithExtensionDoesNotMatchFileInsideDirectory() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let intermediate = try tree.directory("MyProject/Intermediate")
        try tree.file("MyProject/Intermediate/MyProject.uproject")
        #expect(ScanProfile.Pattern.Marker.siblingWithExtension("uproject")
            .matches(directory: intermediate) == false)
    }
}

/// The mistake this is most likely to be written as: comparing the raw suffix
/// rather than the path extension. `hasSuffix("uproject")` is true of
/// `Myuproject`, which is an ordinary file with no dot in sight, and a project
/// directory would be offered for deletion on the strength of it.
@Test func siblingWithExtensionRequiresTheDotNotJustTheLetters() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let intermediate = try tree.directory("MyProject/Intermediate")
        try tree.file("MyProject/Myuproject")
        #expect(ScanProfile.Pattern.Marker.siblingWithExtension("uproject")
            .matches(directory: intermediate) == false)
    }
}

// MARK: - siblingAll
//
// `siblingAny` is an OR and one match is enough. Overriding a safety skip
// needs the opposite: every named sibling must be present, so that reaching a
// directory called `Library` requires proof it is a Unity project and not
// `~/Library`.

@Test func siblingAllMatchesOnlyWhenEveryNameIsPresent() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("MyGame/Library")
        _ = try tree.directory("MyGame/Assets")
        _ = try tree.directory("MyGame/ProjectSettings")
        #expect(ScanProfile.Pattern.Marker.siblingAll(["Assets", "ProjectSettings"])
            .matches(directory: library))
    }
}

@Test func siblingAllRejectsWhenOnlySomeArePresent() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("MyGame/Library")
        _ = try tree.directory("MyGame/Assets")
        #expect(ScanProfile.Pattern.Marker.siblingAll(["Assets", "ProjectSettings"])
            .matches(directory: library) == false)
    }
}

/// The case this exists for. A real home directory has a `Library`; it does
/// not have `Assets` and `ProjectSettings` beside it.
@Test func siblingAllRejectsAHomeDirectoryShapedTree() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let library = try tree.directory("home/Library")
        _ = try tree.directory("home/Documents")
        _ = try tree.directory("home/Downloads")
        #expect(ScanProfile.Pattern.Marker.siblingAll(["Assets", "ProjectSettings"])
            .matches(directory: library) == false)
    }
}
