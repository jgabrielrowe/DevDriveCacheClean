import Testing
import Foundation
import os
@testable import DDCCCore

private func makeAppBundle(at url: URL, bundleID: String) throws {
    let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleName": url.deletingPathExtension().lastPathComponent,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appending(path: "Info.plist", directoryHint: .notDirectory))
}

/// Measured: Unity's editors live at
/// /Applications/Unity/Hub/Editor/6000.5.6f1/, depth 4. A depth-2 scan
/// missed them and reported com.unity3d.UnityEditor as a leftover of a live
/// install — the exact class of false "this app is gone" verdict that made
/// orphan detection unshippable.
@Test func anAppNestedFourLevelsDeepIsStillFound() throws {
    try withTempDirectory { root in
        let bundleURL = root.appending(
            path: "Nested/Hub/Editor/1.0/Deep.app", directoryHint: .isDirectory)
        try makeAppBundle(at: bundleURL, bundleID: "com.example.deep")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })

        #expect(apps.isInstalled("com.example.deep"))
        #expect(apps.byID["com.example.deep"]?.bundleURL.standardizedFileURL
            == bundleURL.standardizedFileURL)
        #expect(apps.byID["com.example.deep"]?.displayName == "Deep")
    }
}

/// Launch Services alone resolved 68 of 733 container entries on the
/// development machine; the disk scan unioned with it resolved 308. Neither
/// source alone is adequate, so both are consulted and this pins that the
/// union actually happens.
@Test func anAppKnownOnlyToLaunchServicesIsStillInstalled() throws {
    try withTempDirectory { root in
        let apps = InstalledApps.scan(
            roots: [root],
            launchServices: { id in id == "com.example.ghost" })

        #expect(apps.isInstalled("com.example.ghost"))
        #expect(apps.byID["com.example.ghost"] == nil)
        #expect(!apps.isInstalled("com.example.nowhere"))
    }
}

/// `com.microsoft.VSCode.ShipIt`-style helper bundles nested inside another
/// app's `Contents` own real, sizeable state of their own and must be
/// enumerated as separately installed identities — not treated as invisible
/// interior detail of the app that ships them.
@Test func aHelperAppNestedInsideContentsIsFoundAsItsOwnIdentity() throws {
    try withTempDirectory { root in
        let hostURL = root.appending(path: "Host.app", directoryHint: .isDirectory)
        try makeAppBundle(at: hostURL, bundleID: "com.example.host")
        let helperURL = hostURL.appending(
            path: "Contents/Frameworks/Helper.app", directoryHint: .isDirectory)
        try makeAppBundle(at: helperURL, bundleID: "com.example.host.helper")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })

        #expect(apps.isInstalled("com.example.host"))
        #expect(apps.isInstalled("com.example.host.helper"))
    }
}

/// A `.app` with no `Info.plist` at all cannot be identified — it must be
/// skipped, not crash the scan or abort the rest of the tree.
@Test func anAppWithNoInfoPlistDoesNotCrashTheScan() throws {
    try withTempDirectory { root in
        let broken = root.appending(path: "Broken.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let sibling = root.appending(path: "Sibling.app", directoryHint: .isDirectory)
        try makeAppBundle(at: sibling, bundleID: "com.example.sibling")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })

        #expect(apps.isInstalled("com.example.sibling"))
        #expect(apps.byID.count == 1)
    }
}

/// The walk must not descend into a `.app` looking for further top-level
/// apps — only into its `Contents`, for helpers. A `.app` dropped anywhere
/// else inside a bundle (here, `SharedSupport`, a real Sparkle/Electron
/// convention) is interior detail of the host app, not a separately
/// installed identity, and must not be found — while a genuine
/// `Contents`-nested helper alongside it still must be.
@Test func aDecoyAppOutsideContentsOfAHostIsNotFoundAsATopLevelApp() throws {
    try withTempDirectory { root in
        let hostURL = root.appending(path: "Host.app", directoryHint: .isDirectory)
        try makeAppBundle(at: hostURL, bundleID: "com.example.host2")
        let helperURL = hostURL.appending(
            path: "Contents/Frameworks/Helper.app", directoryHint: .isDirectory)
        try makeAppBundle(at: helperURL, bundleID: "com.example.host2.helper")
        let decoyURL = hostURL.appending(
            path: "SharedSupport/Decoy.app", directoryHint: .isDirectory)
        try makeAppBundle(at: decoyURL, bundleID: "com.example.host2.decoy")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })

        #expect(apps.isInstalled("com.example.host2"))
        #expect(apps.isInstalled("com.example.host2.helper"))
        #expect(!apps.isInstalled("com.example.host2.decoy"))
    }
}

/// Thread-safe call counter for pinning how many times the injected probe
/// actually runs. Wraps a lock rather than a plain `var` because it is
/// captured by an `@Sendable` closure.
private final class CallCounter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<Int>(initialState: 0)
    func increment() { state.withLock { $0 += 1 } }
    var count: Int { state.withLock { $0 } }
}

/// Later tasks are expected to ask `isInstalled` about the same id from more
/// than one stage (claimant scan, footprint assembly, preflight). If the
/// injected probe ran again on every call, that cost would multiply with
/// the number of call sites, not just the number of ids — this pins that it
/// does not: the probe runs at most once per distinct id **in the absence
/// of concurrent first-calls**. This test is single-threaded and every call
/// is sequential, so it cannot and does not pin the concurrent case —
/// `LaunchServicesMemo` deliberately allows two concurrent first-calls for
/// the same id to both probe rather than serialize behind a lock held
/// across a blocking Launch Services round trip.
@Test func theLaunchServicesProbeIsCalledOnlyOncePerDistinctID() throws {
    try withTempDirectory { root in
        let counter = CallCounter()
        let apps = InstalledApps.scan(
            roots: [root],
            launchServices: { id in
                counter.increment()
                return id == "com.example.ghost"
            })

        #expect(apps.isInstalled("com.example.ghost"))
        #expect(apps.isInstalled("com.example.ghost"))
        #expect(apps.isInstalled("com.example.ghost"))
        #expect(!apps.isInstalled("com.example.other"))
        #expect(!apps.isInstalled("com.example.other"))

        #expect(counter.count == 2)
    }
}

/// The scan is partial-tolerant: a `.app` whose `Info.plist` cannot be read,
/// or declares no `CFBundleIdentifier`, is skipped rather than aborting the
/// walk. That leaves `byID` silently short of a bundle that is unambiguously
/// on disk, so `byID` cannot answer "is anything by this name installed?" —
/// and a caller that reads its absence as absence is reading a parse failure
/// as an uninstall. The discovered filenames come from the walk itself,
/// before any plist is opened, so an unreadable one cannot remove a name.
@Test func aBundleWithNoReadableIdentifierIsStillDiscoveredByName() throws {
    try withTempDirectory { root in
        let broken = root.appending(path: "Broken.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleName": "Broken"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: broken.appending(path: "Info.plist", directoryHint: .notDirectory))

        try makeAppBundle(at: root.appending(path: "Fine.app", directoryHint: .isDirectory),
                          bundleID: "com.example.fine")

        let apps = InstalledApps.scan(roots: [root], launchServices: { _ in false })

        // The parse dropped it, exactly as designed.
        #expect(apps.byID.values.contains { $0.bundleURL.lastPathComponent == "Broken.app" } == false)
        // The walk did not.
        #expect(apps.discoveredBundleFilenames.contains("Broken.app"))
        #expect(apps.discoveredBundleFilenames.contains("Fine.app"))
    }
}

// MARK: - the presence sweep cannot be held up by a stalled mount

/// The presence-only sweep lists `/Volumes` and then every mounted volume and
/// its `Applications` folder. A stale network mount answers a directory
/// listing by not answering, and `contentsOfDirectory` has no timeout, so one
/// of them would hold the whole uninstall sweep for as long as the kernel
/// takes to give up on it.
///
/// A listing that misses its deadline is abandoned and answers `.unreadable`
/// — not an empty reading. The caller turning that into no filenames is the
/// release-permitting direction and is why the bound is per root: one stalled
/// mount must not spend a budget the readable roots needed.
@Test func aDirectoryListingThatDoesNotAnswerInTimeIsAbandoned() {
    let slow = InstalledApps.listing(
        of: URL(fileURLWithPath: "/never", isDirectory: true), before: .now() + 0.2,
        reading: { _ in
            Thread.sleep(forTimeInterval: 5)
            return [URL(fileURLWithPath: "/never/TooLate.app")]
        })
    #expect(slow == .unreadable)
    // And specifically not the reading an unbounded caller would have got.
    #expect(slow != .listed(entries: []))

    // The control: the same call answers normally when the listing does.
    let quick = InstalledApps.listing(
        of: URL(fileURLWithPath: "/answered", isDirectory: true), before: .now() + 5,
        reading: { _ in [URL(fileURLWithPath: "/answered")] })
    #expect(quick == .listed(entries: [URL(fileURLWithPath: "/answered")]))
}

/// The bound reaches the caller. A root whose listing cannot finish inside its
/// share of time contributes no filenames, exactly as an unreadable one does —
/// the sweep goes on rather than stopping on it. Forced here by handing the
/// sweep no time at all, over a root that really does hold a bundle.
@Test func aRootThatCannotBeListedInTimeContributesNoFilenames() throws {
    try withTempDirectory { dir in
        let bundle = dir.appending(path: "Outside.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        #expect(InstalledApps.bundleFilenames(directlyUnder: [dir])
            == (["Outside.app"], true))

        // The listing is supplied so the stall is the fixture rather than the
        // timing: five seconds against a deadline of one tenth cannot be won
        // by a lucky scheduler, where a zero budget only reaches this path
        // because a semaphore has not been signalled yet.
        let abandoned = InstalledApps.bundleFilenames(
            directlyUnder: [dir], within: 0.1,
            reading: { root in
                Thread.sleep(forTimeInterval: 5)
                return [root.appending(path: "TooLate.app", directoryHint: .isDirectory)]
            })
        #expect(abandoned.filenames.isEmpty)
        // And says so, rather than handing back a short set that reads like
        // a complete one — see `bundleFilenames`.
        #expect(abandoned.fullyRead == false)
    }
}

// MARK: - "could not look" is not "nothing there"

/// The distinction the whole presence path rests on: a directory that was
/// read and holds nothing is a finding, a directory that could not be read is
/// not. `DirectoryListing` keeps them apart, and this fails the moment
/// `.unreadable` is folded back into an empty `.listed`.
///
/// Three real directories rather than injected errors, because the mapping
/// under test is the one `FileManager` actually produces: ENOENT is `.absent`,
/// EACCES is `.unreadable`, and a directory that answers is `.listed` however
/// little it holds.
@Test func aDirectoryThatCannotBeReadIsNotADirectoryThatIsEmpty() throws {
    guard getuid() != 0 else { return }  // root can list a 000 directory
    try withTempDirectory { root in
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        #expect(InstalledApps.listing(of: empty, before: nil) == .listed(entries: []))
        #expect(InstalledApps.listing(of: locked, before: nil) == .unreadable)
        #expect(InstalledApps.listing(
            of: root.appending(path: "no-such-directory", directoryHint: .isDirectory),
            before: nil) == .absent)

        // The three cannot collapse into each other.
        #expect(InstalledApps.listing(of: locked, before: nil) != .listed(entries: []))
        #expect(InstalledApps.listing(of: locked, before: nil) != .absent)
        #expect(InstalledApps.listing(
            of: root.appending(path: "no-such-directory", directoryHint: .isDirectory),
            before: nil) != .unreadable)
    }
}

/// A presence root that exists but cannot be listed leaves the sweep short,
/// and has to say so. It is the shape a network share the user cannot read
/// takes, and it is not the shape of a root that simply is not there: three of
/// the four fixed roots do not exist on a typical machine, and marking those
/// short would withhold the app signal on every machine.
@Test func aPresenceRootThatExistsButCannotBeListedReadsShort() throws {
    guard getuid() != 0 else { return }  // root can list a 000 directory
    try withTempDirectory { root in
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let blocked = InstalledApps.bundleFilenames(directlyUnder: [locked])
        #expect(blocked.filenames.isEmpty)
        #expect(blocked.fullyRead == false)

        // A root that is simply not there is the common case and is NOT a
        // short read: it holds nothing, and that is a reading.
        let missing = InstalledApps.bundleFilenames(
            directlyUnder: [root.appending(path: "no-such-directory", directoryHint: .isDirectory)])
        #expect(missing.filenames.isEmpty)
        #expect(missing.fullyRead)

        // And a root that answers still reads whole beside neither of them.
        let bundle = root.appending(path: "Outside.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(InstalledApps.bundleFilenames(directlyUnder: [root])
            == (["Outside.app"], true))
    }
}

/// The scan drops a subtree it cannot list — correctly, since one bad
/// directory must not lose the whole walk — but `discoveredBundleFilenames`
/// then comes back short of every bundle under it with nothing recording the
/// fact. That set is half the union that proves a cask absent, so an
/// unreadable scan root silently releases the zap paths of every product
/// living inside it.
@Test func aSubtreeTheScanCannotListLeavesTheDiscoveredNamesShort() throws {
    guard getuid() != 0 else { return }  // root can list a 000 directory
    try withTempDirectory { root in
        try makeAppBundle(
            at: root.appending(path: "Fine.app", directoryHint: .isDirectory),
            bundleID: "com.example.fine")
        let locked = root.appending(path: "Vendor", directoryHint: .isDirectory)
        try makeAppBundle(
            at: locked.appending(path: "Hidden.app", directoryHint: .isDirectory),
            bundleID: "com.example.hidden")

        // The control comes first, while the subtree is still readable: the
        // same fixture reads whole, so the flag below is the permissions and
        // not the tree.
        let whole = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        #expect(whole.discoveredBundleFilenames == ["Fine.app", "Hidden.app"])
        #expect(whole.discoveredBundleFilenamesFullyRead)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let short = InstalledApps.scan(roots: [root], launchServices: { _ in false })
        // The bundle that is still on disk is gone from the set, exactly as
        // before — dropping the subtree is the right call.
        #expect(short.discoveredBundleFilenames == ["Fine.app"])
        // What is new is that the set now says it is short.
        #expect(short.discoveredBundleFilenamesFullyRead == false)
    }
}

/// A scan root that is not there is not a failure to read one. `defaultRoots`
/// includes `~/Applications` precisely because it is often absent, and a scan
/// whose roots simply do not exist must not report itself short — that would
/// withhold the app signal on the machines the sweep is for.
@Test func aScanRootThatDoesNotExistIsNotAShortRead() throws {
    try withTempDirectory { root in
        try makeAppBundle(
            at: root.appending(path: "Fine.app", directoryHint: .isDirectory),
            bundleID: "com.example.fine")
        let apps = InstalledApps.scan(
            roots: [root, root.appending(path: "no-such-root", directoryHint: .isDirectory)],
            launchServices: { _ in false })
        #expect(apps.discoveredBundleFilenames == ["Fine.app"])
        #expect(apps.discoveredBundleFilenamesFullyRead)
    }
}

/// A bundle the walk cannot confirm is a directory must still be discovered by
/// name.
///
/// `/Applications/Safari.app` is a relative symlink into the cryptex volume,
/// and asking its URL whether it is a directory answers *no* — as it does for
/// the `Updater.app` symlink Sparkle ships inside its framework. The bundle is
/// unambiguously installed; only the type read failed to say so. Dropping it
/// leaves `discoveredBundleFilenames` short of a live application, and a name
/// missing from that set is what proves a cask absent and releases the paths
/// it was refusing.
///
/// Reproduced with a symlink to a bundle inside a directory this cannot
/// traverse, which is what makes the type unresolvable. The unreadable
/// directory is kept outside the scan root on purpose: the walk must be able
/// to read every directory it is given, so the name below is recovered by
/// keeping it rather than by the whole-scan short flag.
@Test func aBundleWhoseTypeCannotBeConfirmedIsStillDiscoveredByName() throws {
    guard getuid() != 0 else { return }  // root can traverse a 000 directory
    try withTempDirectory { root in
        let appsRoot = root.appending(path: "Applications", directoryHint: .isDirectory)
        let vault = root.appending(path: "vault", directoryHint: .isDirectory)
        try makeAppBundle(
            at: appsRoot.appending(path: "Real.app", directoryHint: .isDirectory),
            bundleID: "com.example.real")
        try makeAppBundle(
            at: vault.appending(path: "Outside.app", directoryHint: .isDirectory),
            bundleID: "com.example.outside")
        try FileManager.default.createSymbolicLink(
            at: appsRoot.appending(path: "Outside.app", directoryHint: .isDirectory),
            withDestinationURL: vault.appending(path: "Outside.app", directoryHint: .isDirectory))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: vault.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: vault.path)
        }

        // The fixture really does defeat the type read, which is the whole
        // premise: a link that resolved normally would prove nothing.
        let link = appsRoot.appending(path: "Outside.app", directoryHint: .isDirectory)
        #expect((try? link.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true)

        let apps = InstalledApps.scan(roots: [appsRoot], launchServices: { _ in false })

        // The name is kept, because the name is all the presence question needs.
        #expect(apps.discoveredBundleFilenames == ["Real.app", "Outside.app"])
        // And kept by keeping it: the flag adds no names, so the assertion
        // above is what proves the name survived, not the one below.
        //
        // The scan does read short here, and honestly so. The helper search
        // descends into this bundle's `Contents` now rather than refusing on
        // the same type read that already misjudged the bundle itself — and
        // that `Contents` is behind the unreadable directory, so whatever
        // helpers it holds went uncounted. Reporting complete over that is the
        // confusion this whole reader exists to avoid.
        //
        // It is not the sledgehammer of marking a sweep short instead of
        // keeping the name: that stays refused, and is pinned by
        // `aHelperInsideABundleWhoseTypeCannotBeConfirmedIsStillFound`, whose
        // bundle is unresolvable in the same way but readable inside — the
        // shape that actually occurs, all six of them on a measured machine.
        #expect(!apps.discoveredBundleFilenamesFullyRead)
        // Nothing downstream is fooled into treating it as a readable bundle —
        // its `Info.plist` is behind the same unreadable directory, so `byID`
        // drops it exactly as it drops any bundle it cannot parse.
        #expect(apps.byID["com.example.outside"] == nil)
        #expect(apps.byID["com.example.real"] != nil)
    }
}

/// The helper search inside a bundle must not be refused by the same type read
/// that already proved unreliable for the bundle itself.
///
/// `/Applications/Safari.app` is a symlink into the cryptex volume, and asking
/// its URL whether it is a directory answers *no* — yet
/// `/Applications/Safari.app/Contents` lists nine entries perfectly well.
/// Measured on this machine: all six bundles whose type will not confirm are
/// listable, Safari among them. So the type read was refusing a descent the
/// filesystem would have allowed, and any helper bundle inside such an app was
/// never discovered. A helper missing from `discoveredBundleFilenames` is a
/// name a cask can be proved absent by, which releases the paths it refused.
///
/// The listing itself is the authority — it distinguishes "nothing there" from
/// "could not read" already. The type read is kept only to skip an entry
/// confirmed to be a *regular file*, where a descent would report ENOTDIR as
/// unreadable and mark the whole scan short over a stray file named `*.app`.
@Test func aHelperInsideABundleWhoseTypeCannotBeConfirmedIsStillFound() throws {
    try withTempDirectory { root in
        let appsRoot = root.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appsRoot, withIntermediateDirectories: true)
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)

        // The real bundle, with a helper inside its Contents, sitting outside
        // the scan root so only the symlink can reach it.
        let realURL = elsewhere.appending(path: "Linked.app", directoryHint: .isDirectory)
        try makeAppBundle(at: realURL, bundleID: "com.example.linked")
        try makeAppBundle(
            at: realURL.appending(path: "Contents/Frameworks/Updater.app",
                                  directoryHint: .isDirectory),
            bundleID: "com.example.linked.updater")

        let link = appsRoot.appending(path: "Linked.app", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realURL)

        // A plain file wearing the extension: the one entry the type read must
        // still refuse, because descending into it throws ENOTDIR and would
        // declare the whole scan short.
        try Data("not a bundle".utf8).write(
            to: appsRoot.appending(path: "Stray.app", directoryHint: .notDirectory))

        // The fixture really does defeat the type read on the link, which is
        // the premise: a link answering "directory" would prove nothing.
        #expect((try? link.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true)

        let apps = InstalledApps.scan(roots: [appsRoot], launchServices: { _ in false })

        #expect(apps.discoveredBundleFilenames.contains("Updater.app"))
        #expect(apps.isInstalled("com.example.linked.updater"))
        // The stray file contributes its name and costs nothing else: the scan
        // read every directory it was given.
        #expect(apps.discoveredBundleFilenames.contains("Stray.app"))
        #expect(apps.discoveredBundleFilenamesFullyRead)
    }
}

/// A presence root that is a symlink to a readable directory must be read, not
/// counted as a root that would not open.
///
/// `/Volumes/Macintosh HD` is a symlink to `/` on essentially every modern Mac,
/// and `contentsOfDirectory` on it fails with the same error an unreadable
/// directory gives — while `/` itself lists perfectly well. `presenceOnlyRoots`
/// hands that firmlink over as a root, so the sweep reported short on every
/// run, `installedAppFilenamesFullyRead` was false for every sweep, and no cask
/// declaring an app could ever be proved absent. Measured: that alone took the
/// whole presence relaxation from 4.80 GB across 18 paths to nothing.
///
/// Same shape as the bundle whose type will not confirm, one level out: a
/// symlink that resolves to something readable must not be reported as
/// unreadable.
@Test func aPresenceRootThatIsASymlinkToAReadableDirectoryIsRead() throws {
    try withTempDirectory { root in
        let real = root.appending(path: "real", directoryHint: .isDirectory)
        try makeAppBundle(
            at: real.appending(path: "Linked.app", directoryHint: .isDirectory),
            bundleID: "com.example.linked")
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The premise: reading the link directly is what fails, exactly as
        // `/Volumes/Macintosh HD` does.
        #expect((try? FileManager.default.contentsOfDirectory(
            at: link, includingPropertiesForKeys: nil, options: [])) == nil)

        let read = InstalledApps.bundleFilenames(directlyUnder: [link])
        #expect(read.filenames == ["Linked.app"])
        #expect(read.fullyRead)
    }
}

/// Two roots that resolve to one directory are read once.
///
/// The firmlink yields `/Volumes/Macintosh HD/Applications` beside
/// `/Applications`, so the boot volume's bundles were enumerated twice. The
/// waste is the smaller half: a second reading of names already in hand can
/// fail — a deadline spent on a stalled mount is the realistic way — and
/// report the sweep short over a directory that was read successfully moments
/// before.
@Test func twoRootsResolvingToOneDirectoryAreReadOnce() throws {
    try withTempDirectory { root in
        let real = root.appending(path: "real", directoryHint: .isDirectory)
        try makeAppBundle(
            at: real.appending(path: "Once.app", directoryHint: .isDirectory),
            bundleID: "com.example.once")
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Succeeds once, then fails — so a second reading of the same
        // directory would take the sweep short. Both roots resolve to one
        // path, so nothing but the call order can tell them apart, which is
        // the point: without the deduplication the second call happens.
        let calls = CallCounter()
        let read = InstalledApps.bundleFilenames(
            directlyUnder: [real, link], within: InstalledApps.listingBudget,
            reading: { directory in
                calls.increment()
                guard calls.count == 1 else { throw CocoaError(.fileReadNoPermission) }
                return try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [])
            })

        #expect(calls.count == 1)
        #expect(read.filenames == ["Once.app"])
        #expect(read.fullyRead)
    }
}
