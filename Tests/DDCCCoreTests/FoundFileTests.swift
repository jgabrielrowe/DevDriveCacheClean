import Testing
import Foundation
@testable import DDCCCore

private let path = URL(fileURLWithPath: "/tmp/a.bin")

/// Every other model in this package compares by value. `FoundFile` compared by
/// a random UUID, so two rows describing the same file were unequal — which
/// makes `contains`, `firstIndex(of:)` and test assertions all mean something
/// other than what they read as.
@Test func twoFoundFilesDescribingTheSameFileAreEqual() {
    let a = FoundFile(path: path, sizeBytes: 10, lastModified: nil, isBundle: false)
    let b = FoundFile(path: path, sizeBytes: 10, lastModified: nil, isBundle: false)
    #expect(a == b)
    #expect(a.id != b.id)
}

/// Each field has to participate, or the equality is a weaker claim than it
/// looks. Written as one differing field at a time for the same reason
/// `ScanCompleteness.isExact` is tested that way.
@Test func anyDifferingFieldMakesThemUnequal() {
    let base = FoundFile(path: path, sizeBytes: 10, lastModified: nil, isBundle: false)
    #expect(base != FoundFile(
        path: URL(fileURLWithPath: "/tmp/b.bin"), sizeBytes: 10,
        lastModified: nil, isBundle: false))
    #expect(base != FoundFile(path: path, sizeBytes: 11, lastModified: nil, isBundle: false))
    #expect(base != FoundFile(path: path, sizeBytes: 10, lastModified: Date(), isBundle: false))
    #expect(base != FoundFile(path: path, sizeBytes: 10, lastModified: nil, isBundle: true))
    #expect(base != FoundFile(
        path: path, sizeBytes: 10, lastModified: nil, isBundle: false, partialRead: true))
}

/// `isBundle` and `relativePath` had no direct coverage of their own.
@Test func isBundleAndRelativePathReportWhatTheyAreGiven() {
    let bundle = FoundFile(
        path: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Projects/App.app"),
        sizeBytes: 10, lastModified: nil, isBundle: true)
    #expect(bundle.isBundle)
    #expect(bundle.relativePath == "~/Projects/App.app")

    let outsideHome = FoundFile(
        path: URL(fileURLWithPath: "/Volumes/Big/x.bin"),
        sizeBytes: 10, lastModified: nil, isBundle: false)
    #expect(!outsideHome.isBundle)
    // No home prefix to replace, so the path is unchanged rather than mangled.
    #expect(outsideHome.relativePath == "/Volumes/Big/x.bin")
}

@Test func foundFileIsAlwaysDeletableAndRemovable() {
    let file = FoundFile(
        path: URL(fileURLWithPath: "/tmp/big.mov"),
        sizeBytes: 42,
        lastModified: nil,
        isBundle: false
    )
    #expect(file.isDeletable)
    #expect(file.removability == .removable)
    #expect(file.displayName == "big.mov")
    #expect(file.sizeBytes == 42)
}

/// The view invites the reading "you have not used this". The modified date
/// cannot support that, so the wording is part of the model rather than left
/// to each call site to get right.
@Test func foundFileDescribesAgeAsUnmodifiedNeverUnused() {
    let old = Date(timeIntervalSinceNow: -60 * 60 * 24 * 400)
    let file = FoundFile(
        path: URL(fileURLWithPath: "/tmp/big.mov"),
        sizeBytes: 1,
        lastModified: old,
        isBundle: false
    )
    let text = file.unmodifiedDescription
    #expect(text.localizedCaseInsensitiveContains("unmodified"))
    #expect(text.localizedCaseInsensitiveContains("unused") == false)
}

@Test func foundFileWithNoModifiedDateSaysSoRatherThanGuessing() {
    let file = FoundFile(
        path: URL(fileURLWithPath: "/tmp/big.mov"),
        sizeBytes: 1,
        lastModified: nil,
        isBundle: false
    )
    #expect(file.unmodifiedDescription == "Modified date unknown")
}
