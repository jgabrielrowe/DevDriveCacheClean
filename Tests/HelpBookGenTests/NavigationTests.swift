import Testing
import Foundation
@testable import HelpBookGen

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func markdownNames(in relativePath: String) throws -> Set<String> {
    let directory = packageRoot.appending(path: relativePath)
    return Set(
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
    )
}

/// The tripwire. A page that exists but is not placed in `Navigation` would
/// still be built and still be searchable, but would be unreachable from every
/// other page — the exact silent failure this whole nav exists to end. A name
/// in `Navigation` with no page behind it would render a dead link.
@Test func navigationAndDiskAgreeOnWhichPagesExist() throws {
    let onDisk = try markdownNames(in: "Help/pages").union(markdownNames(in: "Help/generated"))
    let placed = Set(Navigation.all)

    #expect(placed.subtracting(onDisk).isEmpty,
            "Navigation names pages that do not exist: \(placed.subtracting(onDisk).sorted())")
    #expect(onDisk.subtracting(placed).isEmpty,
            "pages exist that Navigation does not place: \(onDisk.subtracting(placed).sorted())")
}

/// Group membership decides which heading a page appears under. Getting it
/// wrong files a reference page among the narrative ones, which reads as a
/// mistake rather than failing.
@Test func eachNavigationGroupMatchesTheDirectoryItsPagesLiveIn() throws {
    let authored = try markdownNames(in: "Help/pages")
    let generated = try markdownNames(in: "Help/generated")

    for name in Navigation.topics {
        #expect(authored.contains(name), "\(name) is listed as a topic but is not in Help/pages")
    }
    for name in Navigation.reference {
        #expect(generated.contains(name), "\(name) is listed as reference but is not in Help/generated")
    }
    #expect(authored.contains(Navigation.home), "\(Navigation.home) is not in Help/pages")
}

/// `all` is what the nav renders. A duplicate would render the page twice.
@Test func navigationListsEachPageExactlyOnce() {
    #expect(Set(Navigation.all).count == Navigation.all.count,
            "Navigation.all contains a duplicate: \(Navigation.all)")
}
