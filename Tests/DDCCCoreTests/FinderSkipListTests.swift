import Testing
import Foundation
@testable import DDCCCore

@Test func declaredDirectoryNamesComeFromTheProfileTable() {
    let names = ScanProfile.declaredDirectoryNames
    #expect(names.contains("node_modules"))
    #expect(names.contains(".venv"))
    #expect(names.contains("target"))
    #expect(names.contains(".build"))
    #expect(names.contains("Pods"))
}

/// The three sources are unioned. A derivation that silently returned an
/// empty set from any one of them would flood the Files view with artifacts
/// the Caches view already explains, and would still pass every other test
/// in this suite — so each source is asserted separately.
@Test func skipListDrawsFromAllThreeSources() {
    let list = FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths)

    // Source 1: FileScanner's own walk exclusions.
    #expect(list.skipsDirectory(named: "Library"))
    #expect(list.skipsDirectory(named: ".git"))

    // Source 2: directory-name patterns in ScanProfile.
    #expect(list.skipsDirectory(named: "node_modules"))

    // Source 3: absolute paths in ScanProfile, which is the source most
    // easily forgotten — these live OUTSIDE ~/Library, so skipping Library
    // does not cover them.
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(list.skipsPath(home.appending(path: ".cargo/registry")))
    #expect(list.skipsPath(home.appending(path: ".m2/repository")))
    #expect(list.skipsPath(home.appending(path: ".cache/uv")))
}

@Test func skipListDoesNotSkipOrdinaryDirectories() {
    let list = FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths)
    #expect(list.skipsDirectory(named: "Documents") == false)
    #expect(list.skipsDirectory(named: "projects") == false)
    #expect(list.skipsPath(URL(fileURLWithPath: "/Users/someone/Movies")) == false)
}

/// A declared path's descendants are inside a directory we never enter, so
/// the prefix check must match them too, not just the exact path.
@Test func skipListSkipsDescendantsOfADeclaredPath() {
    let list = FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths)
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(list.skipsPath(home.appending(path: ".cargo/registry/cache/deep/file.crate")))
}

/// A sibling whose name merely starts with a declared path's name is not
/// inside it. Without a separator in the prefix check, "~/.cargo/registry2"
/// would be skipped because its string starts with "~/.cargo/registry".
@Test func skipListDoesNotSkipASiblingWithASharedPrefix() {
    let list = FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths)
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(list.skipsPath(home.appending(path: ".cargo/registry2")) == false)
}

/// The fourth source. `~/.nvm/versions/node` is outside `~/Library`, so the
/// Library skip does not cover it, and `.toolchainVersions` roots are
/// deliberately absent from `declaredAbsolutePaths` — without a source of
/// their own the finder would walk ~3.6 GB of node versions and report as
/// anonymous large directories the exact bytes the Caches view now names.
@Test func toolchainRootsAreSkippedByTheFilesView() {
    let list = FinderSkipList(declaredPaths: ScanProfile.declaredAbsolutePaths)
    let home = FileManager.default.homeDirectoryForCurrentUser

    #expect(list.skipsPath(home.appending(path: ".nvm/versions/node/v18.16.0")))
    #expect(list.skipsPath(home.appending(path: ".nvm/versions/node")))
    // A sibling that merely shares the opening substring must still be walked.
    #expect(list.skipsPath(home.appending(path: ".nvm/versions/nodejs-notes")) == false)
}

/// The guard must not gain the exemption the finder needs. Admitting the
/// versions root as an audited path would exempt the container of every
/// installed version from the depth rules.
@Test func theToolchainRootIsNotAnAuditedPathForTheGuard() {
    #expect(
        ScanProfile.declaredAbsolutePaths.contains { $0.hasSuffix("/.nvm/versions/node") } == false)
    #expect(ScanProfile.declaredToolchainRoots.contains { $0.hasSuffix("/.nvm/versions/node") })
}
