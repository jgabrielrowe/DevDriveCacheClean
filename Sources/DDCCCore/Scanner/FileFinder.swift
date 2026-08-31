// Sources/DDCCCore/Scanner/FileFinder.swift
import Foundation

/// The two thresholds a row must pass. They combine with AND, and either can be
/// disengaged — zero `modifiedBeforeDays` means "any age", a zero
/// `minimumBytes` means "any size".
///
/// The age threshold is stored as **days**, not as a cutoff `Date`. A stored
/// `Date` is a fact about the moment the value was constructed, and this value
/// is constructed once, at launch, and held for the life of the process: the
/// derived day count then drifted past the Age picker's fixed tags (30 / 180 /
/// 365) after about twelve hours of uptime and the picker rendered blank.
/// Days do not drift. The cutoff is resolved at the moment it is needed.
public struct FinderCriteria: Sendable, Equatable {
    public let minimumBytes: Int64
    /// Whole days. Zero means "any age".
    public let modifiedBeforeDays: Int

    public init(minimumBytes: Int64, modifiedBeforeDays: Int) {
        self.minimumBytes = minimumBytes
        self.modifiedBeforeDays = max(0, modifiedBeforeDays)
    }

    public static let defaults = FinderCriteria(
        minimumBytes: 100_000_000, modifiedBeforeDays: 180)

    /// The cutoff this threshold means *now*. Nil when the age test is
    /// disengaged. Takes `now` as a parameter so a test can advance the clock
    /// without waiting.
    public func cutoff(from now: Date = Date()) -> Date? {
        guard modifiedBeforeDays > 0 else { return nil }
        return now.addingTimeInterval(-Double(modifiedBeforeDays) * 60 * 60 * 24)
    }

    /// A missing modification date passes the age test rather than failing it.
    /// Dropping such a file would hide bytes, which is the one direction this
    /// project treats as unacceptable.
    public func matches(sizeBytes: Int64, modified: Date?, now: Date = Date()) -> Bool {
        guard sizeBytes >= minimumBytes else { return false }
        guard let cutoff = cutoff(from: now) else { return true }
        guard let modified else { return true }
        return modified < cutoff
    }
}

public struct FinderReport: Sendable {
    public let files: [FoundFile]
    public let outcome: ScanOutcome
    /// Directories that could not be listed, entries within a listing the
    /// kernel could not describe, bundles whose own metadata could not be
    /// read, and bundles whose enumeration was refused and so arrived as a
    /// zero-byte measurement carrying a denial. Surfaced rather than
    /// swallowed, the same way `partialRead` marks a size as a floor.
    public let unreadableDirectoryCount: Int
    /// Bundles whose sizing was abandoned because cancellation landed before
    /// or during the walk of their contents. They are absent from `files`, so
    /// without this count a stopped run reads as a smaller complete one.
    ///
    /// Deliberately does NOT count files the walk never reached: that number is
    /// unknown, and inventing a bound for it would be a worse lie than the one
    /// this fixes. `outcome == .cancelled` is what says the run as a whole is a
    /// floor; this says how much was dropped from inside it.
    public let unmeasuredCount: Int
    public let duration: TimeInterval

    public init(
        files: [FoundFile],
        outcome: ScanOutcome,
        unreadableDirectoryCount: Int,
        unmeasuredCount: Int,
        duration: TimeInterval
    ) {
        self.files = files
        self.outcome = outcome
        self.unreadableDirectoryCount = unreadableDirectoryCount
        self.unmeasuredCount = unmeasuredCount
        self.duration = duration
    }

    /// Derived rather than stored, so it cannot drift from the three facts it
    /// is made of.
    ///
    /// `unmeasuredItems` is not always zero, though the finder sizes each row
    /// as it discovers it. That holds for regular files, sized from the bulk
    /// reader's own `entry.sizeBytes`. It does not hold for bundles, which go
    /// through `SizeCalculator` and can be abandoned before or during their walk.
    public var completeness: ScanCompleteness {
        ScanCompleteness(
            unreadableDirectories: unreadableDirectoryCount,
            flooredItems: files.filter(\.partialRead).count,
            unmeasuredItems: unmeasuredCount
        )
    }
}

/// Walks a subtree and reports files and bundles passing both thresholds.
///
/// Open-ended, unlike `FileScanner`: nothing vouches for what it finds, which
/// is why its rows are `FoundFile` rather than `ScanResult` and why the UI
/// never pre-selects them.
public actor FileFinder {
    // Sticky: never reset inside `run`. A caller that wants a fresh
    // cancellable walk creates a new `FileFinder`, the same way
    // `AppViewModel` creates a fresh `ScanCoordinator` per scan rather than
    // reusing one — see AppViewModel.swift's `coordinator` comment. Reusing
    // one `FileFinder` across runs would mean the first `cancel()`
    // permanently broke every run after it, which is by design, not a bug
    // to fix here.
    private var isCancelled = false

    /// How many directories pass between `onProgress` calls, plus one call
    /// for the very first directory. `FileScanner.walk` records that a
    /// per-directory-visited callback starved the UI with a main-actor hop
    /// per directory in the home tree; this throttle avoids repeating that
    /// regression here.
    private static let progressInterval = 64

    /// The directory-listing seam. Defaults to the real reader for every
    /// production caller; a test can construct a `FileFinder` with a
    /// different closure to inject a listing `getattrlistbulk` cannot be
    /// made to produce on demand — a truncated `entries` array together
    /// with `readFailed: true`, simulating a syscall that fails partway
    /// through a directory rather than on the very first call. Mirrors
    /// `DeletionService.FileOperations`, whose doc comment states the same
    /// reason: "so tests can pin behaviour" without ever touching the real
    /// filesystem API from a test.
    private let listDirectory: @Sendable (URL) -> BulkDirectoryListing

    public init() {
        listDirectory = { BulkDirectoryReader.entries(of: $0) }
    }

    /// Test-only. Not public: production callers always get the real
    /// reader through `init()`.
    init(listDirectory: @escaping @Sendable (URL) -> BulkDirectoryListing) {
        self.listDirectory = listDirectory
    }

    /// Marks this finder cancelled. Sticky for the lifetime of this actor
    /// instance: once set, `isCancelled` never resets, so a caller wanting
    /// a resumable walk must construct a new `FileFinder`.
    public func cancel() async {
        isCancelled = true
    }

    public func run(
        root: URL,
        criteria: FinderCriteria,
        skipList: FinderSkipList,
        guardContext: PathGuard.Context,
        onProgress: @Sendable @escaping (String) -> Void
    ) async -> FinderReport {
        let start = Date()

        // The skip list is otherwise only ever checked against CHILDREN as
        // the walk descends — see the `entry.isDirectory` branch below. That
        // leaves the search ROOT itself unchecked: pointing the root picker
        // directly at `~/Library`, at a `node_modules`, or at a declared
        // absolute path like `~/.cargo/registry` would traverse it in full
        // and re-report every file inside as an anonymous row — duplicating
        // exactly the bytes the Caches view already explains with a tier,
        // but without the tier. The Caches view owns those paths; reporting
        // them again here would only be noise, not disclosure.
        if skipList.skipsDirectory(named: root.lastPathComponent) || skipList.skipsPath(root) {
            return FinderReport(
                files: [],
                outcome: .finished,
                unreadableDirectoryCount: 0,
                unmeasuredCount: 0,
                duration: Date().timeIntervalSince(start)
            )
        }

        // One instant for the whole run. Resolving per row would judge the
        // first and last file of a long walk against different cutoffs.
        let now = Date()

        var found: [FoundFile] = []
        var unreadable = 0
        var unmeasured = 0
        var queue: [URL] = [root]
        var directoriesVisited = 0

        while let directory = queue.popLast() {
            if isCancelled || Task.isCancelled {
                return FinderReport(
                    files: found.inDisplayOrder(),
                    outcome: .cancelled,
                    unreadableDirectoryCount: unreadable,
                    unmeasuredCount: unmeasured,
                    duration: Date().timeIntervalSince(start)
                )
            }

            // The actor otherwise has no suspension point for the whole
            // walk, which leaves `cancel()` unable to be serviced by a
            // concurrent caller until `run` returns on its own, and holds a
            // cooperative-pool thread for the duration. Yielding once per
            // directory gives both a chance to happen.
            await Task.yield()

            directoriesVisited += 1
            if directoriesVisited == 1 || directoriesVisited % Self.progressInterval == 0 {
                onProgress(directory.path(percentEncoded: false))
            }

            let listing = listDirectory(directory)
            // `readFailed` is the reader's own report that the syscall or the
            // open failed, so `entries` may be a prefix rather than the whole
            // directory — but it is still whatever the reader managed to get
            // before the failure, and throwing it away (along with every
            // subdirectory inside it) would lose more than the failure
            // itself did. Count the failure and still walk what came back:
            // a truncated prefix is more honest than nothing. Do not infer
            // failure from an empty result: a genuinely empty directory is
            // not a failure.
            if listing.readFailed {
                unreadable += 1
            }
            // An entry the kernel could not describe is a hole in this
            // directory's listing, and if it was a directory the walk will
            // never descend into it. Counted the same way a failed listing is,
            // so it reaches the user through `ScanCompleteness` rather than
            // vanishing.
            unreadable += listing.failedEntryCount

            for entry in listing.entries {
                let child = directory.appending(
                    path: entry.name,
                    directoryHint: entry.isDirectory ? .isDirectory : .notDirectory
                )

                if entry.isDirectory {
                    if skipList.skipsDirectory(named: entry.name) { continue }
                    if skipList.skipsPath(child) { continue }

                    // `isPackage` is a per-directory question, and there are
                    // orders of magnitude fewer directories than files, so
                    // resolving it here does not reintroduce the per-file
                    // syscall cost that `BulkDirectoryReader` exists to avoid.
                    if isPackage(child) {
                        appendIfMatching(
                            child, isBundle: true, modified: entry.modified,
                            criteria: criteria, guardContext: guardContext, now: now,
                            into: &found, unmeasured: &unmeasured, unreadable: &unreadable)
                    } else {
                        queue.append(child)
                    }
                    continue
                }

                guard criteria.matches(
                    sizeBytes: entry.sizeBytes, modified: entry.modified, now: now)
                else { continue }
                guard isAllowed(child, in: guardContext) else { continue }

                found.append(FoundFile(
                    path: child,
                    sizeBytes: entry.sizeBytes,
                    lastModified: entry.modified,
                    isBundle: false
                ))
            }
        }

        let cancelledNow = isCancelled || Task.isCancelled
        return FinderReport(
            // Kept on both outcomes. A stopped run's rows are each individually
            // true — the guard allowed them and their sizes were read the same
            // way — so discarding them hides bytes. What must never happen is
            // presenting them as a whole scan, and `outcome` is what prevents
            // that.
            files: found.inDisplayOrder(),
            outcome: cancelledNow ? .cancelled : .finished,
            unreadableDirectoryCount: unreadable,
            unmeasuredCount: unmeasured,
            duration: Date().timeIntervalSince(start)
        )
    }

    /// A bundle's total needs a walk of its contents whatever API performs
    /// it, so this is a deliberate exception to the bulk-read rule. Bundles
    /// are rare enough in a home directory that the cost is bounded.
    private func appendIfMatching(
        _ url: URL,
        isBundle: Bool,
        modified: Date?,
        criteria: FinderCriteria,
        guardContext: PathGuard.Context,
        now: Date,
        into found: inout [FoundFile],
        unmeasured: inout Int,
        unreadable: inout Int
    ) {
        let measurement: SizeMeasurement
        switch SizeCalculator.measure(at: url) {
        case .measured(let value):
            measurement = value
        case .cancelled:
            // Discovered, then abandoned. Dropping it silently is the defect.
            unmeasured += 1
            return
        case .unmeasurable:
            // Exists, refused entirely. Counted the same way a failed directory
            // listing is, so it reaches the user through `ScanCompleteness`.
            unreadable += 1
            return
        }

        // A sealed bundle arrives here as a real measurement of zero bytes with
        // one recorded denial — its stat succeeds and only its enumeration
        // fails. It then fails the size threshold below and is dropped, so the
        // denial has to be banked before that happens or a find that could not
        // read a whole application comes back exact.
        // `partialRead` is exactly "refused something, or not a kind we
        // measure" — the same disjunction the old `unreadableCount > 0` stood
        // for once both halves shared one field. The Files pipeline keeps its
        // plain `Int` counter and stays a floor; see the design's Non-goals.
        if measurement.bytes == 0 && measurement.partialRead {
            unreadable += 1
            return
        }
        guard criteria.matches(sizeBytes: measurement.bytes, modified: modified, now: now)
        else { return }
        guard isAllowed(url, in: guardContext) else { return }
        found.append(FoundFile(
            path: url,
            sizeBytes: measurement.bytes,
            lastModified: modified ?? SizeCalculator.lastModified(at: url),
            isBundle: isBundle,
            partialRead: measurement.partialRead
        ))
    }

    /// Deny-by-default, applied during traversal exactly as
    /// `CandidateResolver` applies it, so a refused path is never displayed
    /// rather than merely blocked at the end. `DeletionService` checks again.
    private func isAllowed(_ url: URL, in context: PathGuard.Context) -> Bool {
        PathGuard.evaluate(url, removability: .removable, in: context) == .allowed
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }
}
