import Testing
import Foundation
@testable import DDCCCore

/// Wraps a cask array as the JWS envelope `CaskIndex.load` expects.
private func writePresenceFixture(casks: String, to url: URL) throws {
    let envelope: [String: Any] = ["payload": casks, "signatures": []]
    try JSONSerialization.data(withJSONObject: envelope).write(to: url)
}

/// Signal 1 — a cask whose `app` artifact names an installed bundle is
/// present, and the comparison ignores filename case for the same reason
/// `CaskIndex.nameKey` exists: macOS's default filesystem is
/// case-insensitive, so a bundle's stored casing is arbitrary.
@Test func aCaskWhoseAppIsInstalledIsNotProvablyAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "installed-one", "artifacts": [ { "app": ["qBittorrent.app"] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["qbittorrent.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("installed-one"))
    }
}

/// Signal 2 — a `pkgutil` pattern is a regular expression matched against
/// installed package ids, anchored whole. A literal-only implementation
/// passes a literal-only test and then matches nothing on a real machine,
/// so this fixture uses a genuine pattern and a receipt that only a regex
/// can reach.
@Test func aCaskWhoseReceiptPatternMatchesAnInstalledPackageIsNotProvablyAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "pkg-one", "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.suite\\\\..*" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Suite" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.suite.fonts"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("pkg-one"))
    }
}

/// A receipt pattern is anchored at both ends. `com.example.suite` must not
/// be satisfied by a receipt merely containing it, or one vendor's presence
/// vouches for every other product sharing the prefix.
@Test func aReceiptPatternMustMatchThePackageIDWhole() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "anchored", "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.suite" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Suite" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.suite.extras"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(presence.isProvablyAbsent("anchored"))
    }
}

/// Signal 3 — a token listed in the Caskroom is present even with no `app`
/// artifact and no receipt pattern. This is the only signal that reaches a
/// `binary`-only cask, which is exactly the peer shape that would otherwise
/// be invisible: measured, `codex` is such a cask on the development
/// machine and shares `~/.codex` with ChatGPT.app.
@Test func aCaskListedInTheCaskroomIsNotProvablyAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "codex", "artifacts": [ { "zap": [ { "trash": "~/.codex" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: ["codex"])

        #expect(!presence.isProvablyAbsent("codex"))
    }
}

/// The fail-closed default, and the single most important assertion in this
/// plan. A cask with no `app` artifact and no receipt pattern has NO
/// positive presence test at all — "not detected" and "not installed" are
/// indistinguishable for it — so it counts as present and its claims keep
/// refusing. Measured: 2,979 of 7,713 catalogue casks are in this class.
///
/// A version that failed open would pass every other test in this file.
@Test func aCaskWithNoPresenceSignalAtAllIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "untestable", "artifacts": [
              { "binary": ["thing"] },
              { "zap": [ { "trash": "~/Library/Application Support/Thing" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("untestable"))
    }
}

/// An unreadable Caskroom is `nil`, which must never be read as "read, and
/// genuinely empty" — the distinction `RecoveredIdentities.installedCaskTokens`
/// already draws. With the Caskroom unknown, a token that no other signal
/// covers loses its third signal and falls back to present.
@Test func anUnreadableCaskroomLeavesATokenTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "codex", "artifacts": [ { "zap": [ { "trash": "~/.codex" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: nil)

        #expect(!presence.isProvablyAbsent("codex"))
    }
}

/// A cask that HAS a positive test and fails it is provably absent — the
/// case the whole release path depends on. Mirrors the measured shape:
/// `microsoft-edge@beta` declares `Microsoft Edge Beta.app`, which is not
/// installed, so it cannot keep refusing `Microsoft/EdgeUpdater`.
@Test func aCaskWhoseOnlyAppIsNotInstalledIsProvablyAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "edge-beta", "artifacts": [
              { "app": ["Microsoft Edge Beta.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft/EdgeUpdater" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Microsoft Edge.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(presence.isProvablyAbsent("edge-beta"))
    }
}

/// An unparseable pattern is not a licence to guess. A cask whose only
/// signal is a regex that will not compile has no usable test, so it falls
/// back to present rather than to absent.
@Test func aCaskWhoseOnlyReceiptPatternIsInvalidIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "broken", "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.(unclosed" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Broken" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.anything"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("broken"))
    }
}

/// The Caskroom is a positive signal only: a hit proves presence, but it
/// must never let a *miss* override a failed `app` test in the other
/// direction. Here `edge-beta` declares an `app` artifact that is not
/// installed — a failed test, on its own provably absent — but its token
/// IS listed in the Caskroom, so Homebrew still records it as installed
/// and the claim must keep refusing.
@Test func aCaskroomHitOverridesAnAppArtifactThatIsNotInstalled() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "edge-beta", "artifacts": [
              { "app": ["Microsoft Edge Beta.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft/EdgeUpdater" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Microsoft Edge.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: ["edge-beta"])

        #expect(!presence.isProvablyAbsent("edge-beta"))
    }
}

/// The critical fail-closed fix: a token this type never examined — because
/// the catalogue's declarations don't mention it at all — must not be
/// reported provably absent. Only a token that reached the end of a run
/// with a usable signal that failed belongs in `provablyAbsent`; anything
/// else, including a token the catalogue has simply never heard of,
/// defaults to "not provably absent" the same as every other unexamined
/// case.
@Test func anUnknownTokenIsNotProvablyAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "codex", "artifacts": [ { "zap": [ { "trash": "~/.codex" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("never-mentioned"))
    }
}

/// The same fix at its most extreme: an index with no declarations at all
/// proves nothing about any token asked of it, including one an unreadable
/// or empty catalogue was never able to describe.
@Test func anEmptyIndexProvesNothingAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: "[]", to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("anything"))
    }
}

/// Whole-match anchoring must happen at compile time, not by comparing a
/// match's range to the string's range. `firstMatch` returns the leftmost
/// alternative that matches anywhere, so an alternation whose shorter
/// branch comes first — `com\.example\.suite|com\.example\.suite\.fonts`
/// against `com.example.suite.fonts` — used to match only the shorter
/// branch and report a range short of the whole string: a false absence,
/// the dangerous direction. Anchoring inside the pattern (`^(?:...)$`)
/// makes the anchors part of what has to match, which alternation cannot
/// route around.
@Test func anAlternationPatternMatchesRegardlessOfAlternativeOrder() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "alt-order", "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.suite|com\\\\.example\\\\.suite\\\\.fonts" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Suite" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.suite.fonts"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("alt-order"))
    }
}

/// A `:pkgutil` pattern is not a usable signal when the receipt database
/// itself could not be read. `receiptPackageIDs: nil` must not silently
/// become "read, and this cask's receipt is not among them" — the same
/// distinction Signal 3 draws for an unreadable Caskroom, one signal over:
/// reading "could not check" as "checked, and it failed" would mark every
/// pkgutil-only cask provably absent on a machine that simply couldn't read
/// its receipts.
@Test func anUnreadableReceiptDatabaseLeavesAPkgutilOnlyCaskTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "pkg-one", "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.suite\\\\..*" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Suite" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: nil,
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("pkg-one"))
    }
}

/// The symmetric case to `aCaskroomHitOverridesAnAppArtifactThatIsNotInstalled`,
/// which makes that test earn its place rather than merely restating it: an
/// installed app is present on its own two-sided test, and a Caskroom
/// *miss* — this cask was not installed via `brew` — must not override that
/// and reclassify it absent. Signal 3 only ever adds presence; it never
/// subtracts it.
@Test func anInstalledAppRemainsPresentWhenTheCaskroomMisses() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "installed-one", "artifacts": [ { "app": ["qBittorrent.app"] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["qbittorrent.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: ["something-else"])

        #expect(!presence.isProvablyAbsent("installed-one"))
    }
}

/// The third instance of the same shape as the receipt-database and
/// Caskroom fixes: an `:app` artifact is not a usable signal when the
/// installed-app enumeration itself could not be performed.
/// `installedAppFilenames: nil` must not silently become "enumerated, and
/// this cask's app is not among them" — the app signal is the largest of
/// the three (most casks declare an `:app` artifact), so getting this wrong
/// would mark the most casks provably absent on a machine whose app
/// enumeration simply failed.
@Test func anUnreadableAppEnumerationLeavesAnAppOnlyCaskTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "installed-one", "artifacts": [ { "app": ["qBittorrent.app"] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("installed-one"))
    }
}

/// `anAlternationPatternMatchesRegardlessOfAlternativeOrder` pins the
/// anchors but not the non-capturing group: dropping `(?:...)` and using
/// bare `^foo|bar$` still happens to satisfy that fixture. This one
/// discriminates the group itself. `^foo|bar$` parses as two independent
/// alternatives, `(^foo)` or `(bar$)`, so `firstMatch` against "foobar"
/// finds "foo" matching the first alternative at the start of the string —
/// a match, wrongly. `^(?:foo|bar)$` requires the whole string to be either
/// "foo" or "bar", which "foobar" is not, so the cask must stay provably
/// absent.
@Test func aPrefixAlternationDoesNotFalselyMatchAcrossTheAnchors() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "prefix-alt", "artifacts": [
              { "uninstall": [ { "pkgutil": "foo|bar" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/PrefixAlt" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["foobar"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(presence.isProvablyAbsent("prefix-alt"))
    }
}

/// Partial evaluation is not complete evaluation. A cask declaring two
/// `pkgutil` patterns — one that compiles and does not match, one that will
/// not compile — has had only half its test run, so the half that ran
/// proves nothing. Marking it provably absent would release its declared
/// paths on evidence never fully evaluated, which is the direction this
/// type exists to refuse.
@Test func aCaskWithOneUncompilableReceiptPatternIsNotProvablyAbsent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "half-tested", "artifacts": [
              { "uninstall": [ { "pkgutil": [
                    "com\\\\.example\\\\.missing", "com.example.(unclosed"] } ] },
              { "zap": [ { "trash": "~/Library/Application Support/HalfTested" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))
        #expect(index.receiptPatterns(forCaskToken: "half-tested").count == 2)

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.somethingelse"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("half-tested"))
    }
}

/// A `pkgutil` array holding an element that is not a string was not fully
/// read: the patterns that survived the parse are a partial test, and a
/// partial test that misses is indistinguishable from a complete one that
/// misses. Absence is only ever proved by a test that actually ran in full,
/// so the receipt signal is dropped here exactly as it is for a pattern
/// that will not compile.
@Test func aCaskWhoseReceiptPatternArrayWasNotFullyReadIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "partly-read", "artifacts": [
              { "uninstall": [ { "pkgutil": ["com\\\\.example\\\\.gone", 42] } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Partly" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("partly-read"))
    }
}

/// The Homebrew 6.0 shape reaches the same harvest through a different
/// branch, so the completeness of its `:pkgutil` array has to be tracked
/// there too. Without this the legacy branch alone would carry the rule and
/// the shape actually shipped today would keep proving absence on a
/// half-read pattern set.
@Test func aHomebrew6ReceiptPatternArrayThatWasNotFullyReadIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        { "casks": { "partly-read-6": { "raw_artifacts": [
              [":zap", { ":pkgutil": ["com\\\\.example\\\\.gone", 42],
                         ":trash": "~/Library/Application Support/Partly" } ] ] } } }
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("partly-read-6"))
    }
}

/// The same rule for the other presence signal. An `:app` artifact this reader
/// cannot turn into an installed bundle name leaves the app test unable to run
/// in full: the names that did survive are compared against the installed
/// filenames, and a miss there is exactly what proves absence. A cask that
/// declares two apps and yields one name has had half its app test run, and
/// half a test that misses is indistinguishable from a whole one that misses.
///
/// The unreadable half is `box-tools`' real shape — a `:target` naming an
/// explicit path under `~/Library` rather than a bundle that lands in an
/// Applications folder, so no filename this sweep enumerates could ever match
/// it. `ftdi-vcp-driver` is the other in the shipped cache.
@Test func aCaskWhoseAppArtifactWasNotFullyReadIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        { "casks": { "partly-read-app": { "raw_artifacts": [
              [":app", ["Vendor.app"]],
              [":app", ["Install Vendor.app/Contents/Resources/Vendor Helper.app"],
                       { ":target": "~/Library/Application Support/Vendor/Vendor Helper.app" }],
              [":zap", { ":trash": "~/Library/Application Support/Vendor" } ] ] } } }
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Something Else.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: nil,
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("partly-read-app"))
    }
}

/// One malformed element must not take a whole stanza array with it while the
/// row still reports its patterns as wholly read. A cask carrying `pkgutil`
/// under both `zap` and `uninstall`, where only one array survives its cast,
/// hands the caller a short pattern set flagged as complete — and a short set
/// that misses is what proves a live product absent.
///
/// Zero occurrences in the shipped cache: every `zap` and `uninstall` value
/// there is an array of dicts. This is the shape the rule is about, not a
/// reading of today's data.
@Test func aCaskWhoseStanzaArrayWasNotFullyReadIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "half-read-stanzas", "artifacts": [
              { "zap": [ { "pkgutil": "com\\\\.example\\\\.gone",
                           "trash": "~/Library/Application Support/Half" } ] },
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.other" }, 42 ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))
        // Positive control: one bad element costs only itself, so both
        // readable stanzas still contributed their pattern — the verdict below
        // is the completeness flag and not an empty index.
        #expect(index.receiptPatterns(forCaskToken: "half-read-stanzas").count == 2)

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("half-read-stanzas"))
    }
}

/// The same rule on the shape actually shipped today. Homebrew 6.0 gives
/// `:zap` and `:uninstall` a single dict, so what fails to read there is the
/// entry itself rather than one element of an array — and dropping it silently
/// leaves the same short-but-complete-looking pattern set.
@Test func aHomebrew6StanzaThatCouldNotBeReadIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        { "casks": { "half-read-6": { "raw_artifacts": [
              [":zap", { ":pkgutil": "com\\\\.example\\\\.gone",
                         ":trash": "~/Library/Application Support/Half" }],
              [":uninstall", "not-a-stanza"] ] } } }
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))
        #expect(index.receiptPatterns(forCaskToken: "half-read-6").count == 1)

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("half-read-6"))
    }
}

/// Negative control for the two above, and the reason completeness is
/// tracked for `pkgutil` alone. A malformed element in a *path* array costs
/// one path and leaves the rest usable — a path is an offer, and an offer
/// that is short is merely smaller. An unread `pkgutil` element is a test
/// that did not run, which is a different kind of loss.
@Test func aPathArrayThatWasNotFullyReadStillContributesItsReadableEntries() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        [ { "token": "mixed-paths", "artifacts": [
              { "app": ["Mixed.app"] },
              { "zap": [ { "trash": ["~/Library/Application Support/Mixed", 42] } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(index.zapPaths(forAppBundleNamed: "Mixed.app", presence: nil)
            == ["\(home)/Library/Application Support/Mixed"])
    }
}

/// The other consumer of the same three gaps. An unreadable `raw_artifacts`
/// entry sitting beside a readable `:app` left the row's app test flagged as
/// wholly run, so a miss against the installed filenames counted as a finding
/// — and the skipped entry is exactly where the app that IS installed may have
/// been declared. A partial test that misses is indistinguishable from a
/// complete one that misses, which is what the completeness flags exist to
/// keep apart.
///
/// This is the direction that costs bytes rather than an anchor: a cask proved
/// absent stops refusing the paths it declares, so a live product's shared
/// directory is released while the product is still installed.
///
/// Both shapes here, in one row each: an entry that is not an array at all,
/// and one whose first member is not an artifact kind.
@Test func aHomebrew6ArtifactEntryThatCouldNotBeReadIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        { "casks": {
            "bad-entry": { "raw_artifacts": [
                [":app", ["Readable.app"]],
                42,
                [":zap", { ":trash": "~/Library/Application Support/Bad" }] ] },
            "no-kind-entry": { "raw_artifacts": [
                [":app", ["AlsoReadable.app"]],
                [42, ["Nameless.app"]],
                [":zap", { ":trash": "~/Library/Application Support/NoKind" }] ] } } }
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))
        // Positive control: one unreadable entry costs only itself, so the
        // readable `:app` beside it still became a name. The verdicts below
        // are the completeness flag and not an empty index.
        #expect(index.declaresApp(forCaskToken: "bad-entry") == true)
        #expect(index.declaresApp(forCaskToken: "no-kind-entry") == true)

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Something Else.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: nil,
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("bad-entry"))
        #expect(!presence.isProvablyAbsent("no-kind-entry"))
    }
}

/// The other half of the same guard. An unreadable entry hides a `:pkgutil`
/// exactly as readily as it hides an `:app`, so a row carrying only receipt
/// patterns is left with a short set flagged as complete — and a short set
/// that misses is what proves a live product absent. Both flags come down for
/// one unreadable entry because nothing about it says which kind it was.
///
/// The second row states the same contract for the whole list being
/// unreadable. `resolve` cannot reach it there — a row with no patterns never
/// runs the receipt test — so this asserts on `presenceInputs`, the published
/// shape `resolve` reads. The flag's meaning is "this row's patterns were read
/// in full", and it is false here, whether or not today's caller branches on
/// it.
@Test func aHomebrew6ArtifactEntryThatCouldNotBeReadShortensThePatternSetToo() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        { "casks": {
            "pkg-bad-entry": { "raw_artifacts": [
                [":uninstall", { ":pkgutil": "com\\\\.example\\\\.gone" }],
                42 ] },
            "whole-list-unread": { "raw_artifacts": 42 } } }
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))
        // Positive control: the readable entry still contributed its pattern,
        // so the verdict below is the completeness flag and not an empty row.
        #expect(index.receiptPatterns(forCaskToken: "pkg-bad-entry").count == 1)

        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!presence.isProvablyAbsent("pkg-bad-entry"))

        let unread = try #require(
            index.presenceInputs().first { $0.token == "whole-list-unread" })
        #expect(!unread.receiptPatternsFullyRead)
    }
}

/// A `pkgutil` miss is only a finding when the receipt database it missed
/// against was read in full. One receipt inside a readable database that could
/// not be parsed leaves the id set short, and the pattern that would have
/// matched the dropped receipt misses instead — proving a live product absent
/// and releasing the paths its cask was refusing.
///
/// Exactly the rule `installedAppFilenamesFullyRead` carries for the other
/// two-sided signal, and for the same reason: a match is proof of presence
/// whichever id produced it, so the ids are kept rather than discarded.
/// Discarding them would be worse than the bug — with no receipt signal the
/// row falls through to the app arm, whose miss can then prove absence on its
/// own, which is the trade an earlier attempt at this made in reverse.
@Test func aPkgutilMissAgainstAShortReceiptDatabaseIsTreatedAsPresent() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.jws.json")
        try writePresenceFixture(casks: """
        { "casks": { "pkg-only": { "raw_artifacts": [
              [":uninstall", { ":pkgutil": "com\\\\.example\\\\.suite" }],
              [":zap", { ":trash": "~/Library/Application Support/Suite" } ] ] } } }
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        // Read whole and missing: the miss is a finding, so the cask is
        // provably absent. Without this the assertion below would pass over a
        // signal that had simply stopped working.
        #expect(CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: []).isProvablyAbsent("pkg-only"))

        // The same miss against a database known to be short proves nothing.
        #expect(!CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.unrelated"],
            receiptPackageIDsFullyRead: false,
            caskroomTokens: []).isProvablyAbsent("pkg-only"))

        // And a match still stands whatever the flag says: a short set is
        // short, not wrong, so an id found in it is still proof of presence.
        #expect(!CaskPresence.resolve(
            index: index,
            installedAppFilenames: nil,
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: ["com.example.suite"],
            receiptPackageIDsFullyRead: false,
            caskroomTokens: []).isProvablyAbsent("pkg-only"))
    }
}
