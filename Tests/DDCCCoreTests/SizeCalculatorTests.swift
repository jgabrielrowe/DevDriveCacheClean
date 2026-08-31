import Testing
import Foundation
@testable import DDCCCore

@Test func countsPlainFiles() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("a.bin", byteCount: 4096)
        try tree.file("nested/b.bin", byteCount: 4096)
        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(measurement.bytes >= 8192)
        #expect(measurement.partialRead == false)
    }
}

/// Hidden files were skipped, so node_modules/.bin and similar counted zero.
@Test func countsHiddenFiles() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file(".hidden.bin", byteCount: 8192)
        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(measurement.bytes >= 8192)
    }
}

@Test func countsFilesInsideHiddenDirectories() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file(".cache/inner.bin", byteCount: 8192)
        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(measurement.bytes >= 8192)
    }
}

/// Package descendants were skipped, so DerivedData — which is mostly
/// bundles — reported a small fraction of its real size.
@Test func countsBundleContents() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("Build/Products/Thing.app/Contents/MacOS/Thing", byteCount: 65536)
        try tree.file("Build/Products/Thing.framework/Versions/A/Thing", byteCount: 65536)
        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(measurement.bytes >= 131072)
    }
}

@Test func emptyDirectoryMeasuresZeroWithoutError() throws {
    try withTempDirectory { root in
        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(measurement.bytes == 0)
        #expect(measurement.partialRead == false)
    }
}

@Test func missingDirectoryMeasuresZero() throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let measurement = try #require(SizeCalculator.measure(at: missing).measurement)
    #expect(measurement.bytes == 0)
}

@Test func unreadableSubdirectoryIsNamedAndFlagged() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("readable.bin", byteCount: 4096)
        let locked = try tree.directory("locked")
        try tree.file("locked/secret.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
        }

        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        // Named, not tallied. A count cannot be deduplicated against the same
        // directory found by the walk; this string can — and it is the same
        // string the walk would produce, because both go through
        // `Candidate.normalizedPathKey`.
        #expect(measurement.unreadablePaths == [Candidate.normalizedPathKey(for: locked)])
        #expect(measurement.unmeasurableKind == false)
        #expect(measurement.partialRead == true)
        #expect(measurement.bytes >= 4096)
    }
}

/// Two sealed siblings are two named refusals, not one and not a tally.
///
/// The companion to `unreadableSubdirectoryIsNamedAndFlagged` above, which uses
/// a single seal: with one refusal, "kept the set" and "reduced the set to one
/// path" are numerically identical, so a single-seal fixture cannot tell them
/// apart. Two can, and this is the layer the second path has to survive from —
/// `Measurer` can only carry forward what the sizer records.
///
/// Siblings rather than nested, deliberately: `RefusalSet` absorbs a refusal
/// that lives inside another refusal, so nested seals would legitimately
/// collapse to one further up and prove nothing here.
@Test func twoSealedSiblingsAreTwoNamedRefusals() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("readable.bin", byteCount: 4096)
        let firstSeal = try tree.directory("sealedOne")
        try tree.file("sealedOne/secret.bin", byteCount: 4096)
        let secondSeal = try tree.directory("sealedTwo")
        try tree.file("sealedTwo/secret.bin", byteCount: 4096)
        for seal in [firstSeal, secondSeal] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: seal.path(percentEncoded: false))
        }
        defer {
            for seal in [firstSeal, secondSeal] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: seal.path(percentEncoded: false))
            }
        }

        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        // Exact set equality, both keyed the way the walk keys its own refusals.
        #expect(measurement.unreadablePaths == [
            Candidate.normalizedPathKey(for: firstSeal),
            Candidate.normalizedPathKey(for: secondSeal),
        ])
        #expect(measurement.unmeasurableKind == false)
        #expect(measurement.partialRead == true)
    }
}

/// A refusal count and a not-a-kind-we-measure count are separate fields, and
/// this pins that they stay separate. Nothing refuses us a symlink — it is
/// right there — so folding the two together makes a refusal count that can
/// never be exact, whatever else is fixed.
@Test func aSymlinkIsAnUnmeasurableKindAndNotADenial() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("realDirectory")
        try tree.file("realDirectory/inside.bin", byteCount: 4096)
        let link = try tree.symlink("linkToDirectory", to: target)

        let measurement = try #require(SizeCalculator.measure(at: link).measurement)
        #expect(measurement.unmeasurableKind == true)
        #expect(measurement.unreadablePaths.isEmpty)
        // Unchanged: it still reads as partial to every caller and every view.
        // Correcting the *label* is a separate change; this only stops
        // the data model lying.
        #expect(measurement.partialRead == true)
    }
}

@Test func lastModifiedReturnsADateForAnExistingDirectory() throws {
    try withTempDirectory { root in
        #expect(SizeCalculator.lastModified(at: root) != nil)
    }
}

@Test func lastModifiedIsNilForMissingPath() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(SizeCalculator.lastModified(at: missing) == nil)
}

/// `measure` must not assume its argument is a directory. On a plain file the
/// enumerator fails to open, which would count as a permission denial though
/// nothing was refused — misreporting the byte count as 0 and spuriously
/// flagging `partialRead`.
@Test func measuringARegularFileReturnsItsOwnAllocatedSize() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let file = try tree.file("solo.bin", byteCount: 12345)
        let measurement = try #require(SizeCalculator.measure(at: file).measurement)
        #expect(measurement.bytes > 0)
        #expect(measurement.partialRead == false)
    }
}

/// A missing path is "nothing to measure", not "something I was refused
/// access to" — it must not set `partialRead`.
@Test func measuringANonexistentPathReportsZeroUnreadable() throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    // Absence is not denial. A missing path is a real, complete measurement of
    // nothing — not `.unmeasurable`, which would raise a caveat on every scan
    // for every profile path this machine happens not to have.
    let measurement = try #require(SizeCalculator.measure(at: missing).measurement)
    #expect(measurement.bytes == 0)
    #expect(measurement.partialRead == false)
}

/// Pins the single-file path and the directory-walk path to the same
/// accounting: measuring a file directly must agree with what the walk
/// attributes to that same file when measuring its parent.
@Test func regularFileMeasurementAgreesWithDirectoryWalkAccounting() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let file = try tree.file("solo.bin", byteCount: 12345)
        let direct = try #require(SizeCalculator.measure(at: file).measurement)
        let viaParent = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(direct.bytes == viaParent.bytes)
    }
}

// NOTE: `measure(at:)` is never called on a symlink through the current
// pipeline — `PathGuard` refuses to treat a symlink as a removable leaf, and
// discovery filters candidates on `isDirectory` before sizing runs. These two
// tests protect the public contract of `measure(at:)` itself (it is public
// API on `DDCCCore`, callable with any URL), not a path reachable
// today. Do not delete them as "untestable in practice" — they exist so a
// symlink can never again silently report a confident zero.

@Test func symlinkToADirectoryIsFlaggedNotSilentlyZero() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.directory("realDirectory")
        try tree.file("realDirectory/inside.bin", byteCount: 4096)
        let link = try tree.symlink("linkToDirectory", to: target)

        let measurement = try #require(SizeCalculator.measure(at: link).measurement)
        #expect(measurement.bytes == 0)
        #expect(measurement.unmeasurableKind == true)
        #expect(measurement.partialRead == true)
    }
}

@Test func symlinkToAFileIsFlaggedNotSilentlyZero() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let target = try tree.file("realFile.bin", byteCount: 4096)
        let link = try tree.symlink("linkToFile", to: target)

        let measurement = try #require(SizeCalculator.measure(at: link).measurement)
        #expect(measurement.bytes == 0)
        #expect(measurement.unmeasurableKind == true)
        #expect(measurement.partialRead == true)
    }
}

/// The enumeration loop has to check `Task.isCancelled`, or a cancelled scan
/// keeps walking an in-flight directory to completion — on DerivedData or an
/// 11 GB VM bundle, seconds of unresponsiveness after the user presses Stop.
/// This pins it without racing a wall clock: the
/// task spins on `Task.yield()` until its own cancellation is actually
/// recorded *before* calling `measure`, so `measure` never has a chance to
/// run uncancelled. The fixture has comfortably more entries than one
/// `cancellationCheckInterval` (256), so if the loop's periodic check were
/// ever removed or miscounted, this would fail by returning the full byte
/// count instead of `.cancelled`.
@Test func cancellationDuringEnumerationReturnsCancelledPromptly() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<2000 {
            try tree.file("bulk/file-\(index).bin", byteCount: 4096)
        }

        let task = Task<SizeOutcome, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
            return SizeCalculator.measure(at: root)
        }
        task.cancel()

        let outcome = await task.value
        #expect(outcome == .cancelled)
    }
}

/// Pins that the cancellation contract has no size-dependent carve-out: a
/// directory with far fewer entries than `cancellationCheckInterval` (256)
/// must still return `.cancelled` when cancelled, because the pre-loop check
/// catches it before the loop ever gets a chance to walk it uninterrupted.
/// Before that check was added, a cancelled measurement of a small tree like
/// this one returned its full, correct-but-misleading byte count, breaking
/// the doc comment's promise that cancellation returns `.cancelled`.
@Test func cancellationOfADirectorySmallerThanTheCheckIntervalStillReturnsCancelled() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)
        for index in 0..<10 {
            try tree.file("small/file-\(index).bin", byteCount: 4096)
        }

        let task = Task<SizeOutcome, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
            return SizeCalculator.measure(at: root)
        }
        task.cancel()

        let outcome = await task.value
        #expect(outcome == .cancelled)
    }
}

/// The defect this refactor exists to close: an empty directory, a refused
/// directory and a cancelled walk all returned `SizeMeasurement.zero`, so no
/// caller could tell them apart, and both callers dropped all three. Asserted
/// as three distinct values in one test, because the property is the
/// *distinction* — three separate tests could each pass while two of the cases
/// still collapsed onto each other.
@Test func emptyRefusedAndCancelledAreThreeDistinctOutcomes() async throws {
    try await withTempDirectory { root in
        let tree = FixtureTree(root: root)

        let empty = try tree.directory("empty")

        // Chmodding `refused` itself is not enough to reach `.unmeasurable`:
        // neither `resourceValues(forKeys:)` nor `FileManager.enumerator(at:)`
        // needs execute permission on the directory being read, only on its
        // parent, so that only produces `.measured(.., unreadablePaths: [refused])` —
        // already-distinct, but not the metadata-refusal path this test means
        // to pin. Locking the parent makes the initial stat itself throw.
        let refusedContainer = try tree.directory("refusedContainer")
        let refused = try tree.directory("refusedContainer/refused")
        try tree.file("refusedContainer/refused/inner.bin", byteCount: 4096)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: refusedContainer.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: refusedContainer.path(percentEncoded: false))
        }

        let cancelledTarget = try tree.directory("cancelled")
        for index in 0..<300 {
            try tree.file("cancelled/file-\(index).bin", byteCount: 4096)
        }
        let task = Task<SizeOutcome, Never> {
            while !Task.isCancelled { await Task.yield() }
            return SizeCalculator.measure(at: cancelledTarget)
        }
        task.cancel()

        #expect(SizeCalculator.measure(at: empty) == .measured(.zero))
        #expect(SizeCalculator.measure(at: refused) == .unmeasurable)
        #expect(await task.value == .cancelled)
    }
}

// MARK: - Hard links

/// Content linked twice inside one tree is one thing on disk, and deleting the
/// tree frees it once. Counting each directory entry made a pnpm store or a
/// Homebrew cellar read as a multiple of its real size.
@Test func contentLinkedTwiceInsideTheTreeCountsOnce() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let original = try tree.file("store/payload.bin", byteCount: 65536)
        try tree.hardLink("packages/one/payload.bin", to: original)
        try tree.hardLink("packages/two/payload.bin", to: original)

        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        // Every link lives in this tree, so removing the tree really does
        // release the blocks — once.
        #expect(measurement.bytes >= 65536)
        #expect(measurement.bytes < 131072)
        #expect(measurement.sharedBytesWithheld == 0)
    }
}

/// The pnpm case. `node_modules` links into a store that outlives the delete,
/// so those bytes are not this item's to promise.
@Test func contentLinkedOutsideTheTreeIsWithheldNotCounted() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let store = try tree.file("store/payload.bin", byteCount: 65536)
        let project = try tree.directory("project")
        try tree.hardLink("project/node_modules/payload.bin", to: store)
        try tree.file("project/own.bin", byteCount: 65536)

        let measurement = try #require(SizeCalculator.measure(at: project).measurement)
        // Only `own.bin` is wholly ours. The linked payload survives the delete
        // in the store, so it counts zero — and says how much it left out.
        #expect(measurement.bytes >= 65536)
        #expect(measurement.bytes < 131072)
        #expect(measurement.sharedBytesWithheld >= 65536)
    }
}

/// A single file with another name elsewhere frees nothing when deleted.
@Test func aLoneHardLinkedFileMeasuresZeroAndWithholds() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let original = try tree.file("original.bin", byteCount: 65536)
        try tree.hardLink("elsewhere.bin", to: original)

        let measurement = try #require(SizeCalculator.measure(at: original).measurement)
        #expect(measurement.bytes == 0)
        #expect(measurement.sharedBytesWithheld >= 65536)
    }
}

/// The ordinary case must be untouched: one link, counted, nothing withheld.
@Test func unlinkedFilesWithholdNothing() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        try tree.file("a.bin", byteCount: 65536)
        try tree.file("nested/b.bin", byteCount: 65536)

        let measurement = try #require(SizeCalculator.measure(at: root).measurement)
        #expect(measurement.bytes >= 131072)
        #expect(measurement.sharedBytesWithheld == 0)
        #expect(measurement.partialRead == false)
    }
}

/// Withholding is not a partial read. Nothing refused us and nothing was
/// unreadable; the bytes are simply not this item's to free, which is a
/// finished answer rather than a floor.
@Test func withheldBytesDoNotMakeTheReadPartial() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let store = try tree.file("store/payload.bin", byteCount: 65536)
        let project = try tree.directory("project")
        try tree.hardLink("project/linked.bin", to: store)

        let measurement = try #require(SizeCalculator.measure(at: project).measurement)
        #expect(measurement.partialRead == false)
        #expect(measurement.sharedBytesWithheld >= 65536)
    }
}
