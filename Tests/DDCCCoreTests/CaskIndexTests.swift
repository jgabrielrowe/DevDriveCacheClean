import Testing
import Foundation
@testable import DDCCCore

/// Wraps a cask array as the JWS envelope `CaskIndex.load` expects: the
/// cask JSON lives inside the `payload` field as a *string*, not as nested
/// JSON, exactly as `~/Library/Caches/Homebrew/api/cask.jws.json` stores it
/// (confirmed by inspecting the real 20 MB file once during development —
/// its top level is `{"payload": "<json string>", "signatures": [...]}`).
private func writeJWSFixture(casks: String, to url: URL) throws {
    let envelope: [String: Any] = [
        "payload": casks,
        "signatures": [],
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope)
    try data.write(to: url)
}

private func homePath(_ suffix: String) -> String {
    FileManager.default.homeDirectoryForCurrentUser.path + "/" + suffix
}

/// Path-anchored lookup attributes Chrome's 2.3 GB to 1Password: searching
/// for "Application Support/Google" matched 46 casks on the development
/// machine, mostly apps installing a native-messaging host INTO Chrome's
/// directory (measured: against the real cask cache — e.g. 1Password
/// declares `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/
/// com.1password.1password.json`, a file it drops inside Chrome's own
/// directory). Lookup is app-anchored — bundle name to cask via the cask's
/// `app` artifact, never path to cask — so 1Password's declaration can never
/// surface when looking up Chrome, and Chrome's declaration can never surface
/// when looking up 1Password.
@Test func aCaskThatMerelyWritesIntoAnotherAppsDirectoryDoesNotClaimIt() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "google-chrome",
            "artifacts": [
              { "app": ["Google Chrome.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Google/Chrome" } ] }
            ]
          },
          {
            "token": "1password",
            "artifacts": [
              { "app": ["1Password.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "Google Chrome.app", presence: nil)
            == [homePath("Library/Application Support/Google/Chrome")])
        #expect(index.zapPaths(forAppBundleNamed: "1Password.app", presence: nil)
            == [homePath("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json")])
    }
}

/// Chrome's cask declares both `Application Support/Google/Chrome` and
/// `Application Support/Google`; Edge's declares both
/// `Microsoft/EdgeUpdater` and `Microsoft` (confirmed verbatim against the
/// real cache: Chrome's zap `trash` includes the former, its `rmdir`
/// includes the latter; Edge's `trash` includes the former, its `rmdir`
/// includes the latter). Take the descendants, refuse the bare ancestor —
/// each cask here narrows against only its *own* declarations, no other
/// cask involved.
@Test func whenACaskDeclaresBothAPathAndItsAncestorOnlyTheDescendantSurvives() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "google-chrome",
            "artifacts": [
              { "app": ["Google Chrome.app"] },
              { "zap": [ {
                  "trash": "~/Library/Application Support/Google/Chrome",
                  "rmdir": "~/Library/Application Support/Google"
              } ] }
            ]
          },
          {
            "token": "microsoft-edge",
            "artifacts": [
              { "app": ["Microsoft Edge.app"] },
              { "zap": [ {
                  "trash": "~/Library/Application Support/Microsoft/EdgeUpdater",
                  "rmdir": "~/Library/Application Support/Microsoft"
              } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "Google Chrome.app", presence: nil)
            == [homePath("Library/Application Support/Google/Chrome")])
        #expect(index.zapPaths(forAppBundleNamed: "Microsoft Edge.app", presence: nil)
            == [homePath("Library/Application Support/Microsoft/EdgeUpdater")])
    }
}

/// `Application Support/Microsoft` is 1,413 MB holding Word and Excel data,
/// both installed on this machine. Honouring Edge's stanza literally
/// destroys Office. Confirmed against the real cache: `microsoft-edge`'s
/// zap `rmdir` and `microsoft-word`'s zap `trash` both declare the
/// identical literal path `~/Library/Application Support/Microsoft` — two
/// unrelated casks independently claiming the same directory is exactly the
/// signal that it is a shared vendor root, not Edge's exclusive territory,
/// so it is refused for Edge even though nothing in Edge's *own* list
/// disambiguates it (unlike the Rule 2 case above, Edge here declares
/// nothing more specific of its own — only the cross-cask duplicate claim
/// catches this).
@Test func aPathDeclaredIdenticallyByTwoUnrelatedCasksIsRefused() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "microsoft-edge",
            "artifacts": [
              { "app": ["Microsoft Edge.app"] },
              { "zap": [ { "rmdir": "~/Library/Application Support/Microsoft" } ] }
            ]
          },
          {
            "token": "microsoft-word",
            "artifacts": [
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "Microsoft Edge.app", presence: nil) == [])
    }
}

/// Homebrew not being installed is a normal state: `~/Library/Caches/
/// Homebrew/api/cask.jws.json` is simply absent on a machine that never
/// installed it, and that must not be treated as an error.
@Test func aMissingHomebrewCacheYieldsNoIndexRatherThanAnError() throws {
    try withTempDirectory { dir in
        let missing = dir.appending(path: "does-not-exist.jws.json")
        #expect(CaskIndex.load(from: missing) == nil)
    }
}

/// 1Password's own zap stanza uses globs (e.g. `~/Library/Application
/// Scripts/2BUA8C4S2C.com.1password*`), confirmed against the real cache —
/// this is not a rare shape. A glob-bearing path is skipped rather than
/// naively treated as a literal path, and the skip is counted so a caller
/// can disclose the gap rather than silently under-reporting.
@Test func aGlobBearingZapPathIsSkippedAndCountedRatherThanTreatedLiterally() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "1password",
            "artifacts": [
              { "app": ["1Password.app"] },
              { "zap": [ {
                  "trash": [
                    "~/Library/Application Scripts/2BUA8C4S2C.com.1password*",
                    "~/Library/Application Support/1Password"
                  ]
              } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "1Password.app", presence: nil)
            == [homePath("Library/Application Support/1Password")])
        #expect(index.skippedGlobPathCount == 1)
    }
}

// MARK: - Homebrew 6.0's cache format
//
// Found `~/Library/Caches/Homebrew/api/cask.jws.json` no longer
// exists on a machine running Homebrew 6.0.18. The cask data moved to
// `api/internal/packages.<bottle-tag>.jws.json`, and the shape changed with
// it. The JWS envelope is the same; everything inside it differs:
//
//   old   payload is an ARRAY of casks, each `{"token", "artifacts": [...]}`
//         with `artifacts` entries keyed `"app"` / `"zap"`, `zap` an ARRAY
//         of stanzas keyed `"trash"` / `"delete"` / `"rmdir"`
//
//   new   payload is an OBJECT `{"casks": {token: cask}}` — the token is the
//         map key, not a field — and each cask carries `raw_artifacts`, an
//         array of two-element `[":app", [...]]` / `[":zap", {...}]` pairs
//         with Ruby symbol keys. `:zap` is a DICT, not an array of them.
//
// Measured against the real 7,702-cask file: every entry uses
// `raw_artifacts`, none carries `artifacts` or `token`, and `:zap` is a
// dict in all 4,646 casks that have one. Its keys include `:launchctl`,
// `:pkgutil`, `:script`, `:login_item` and `:kext` alongside the three path
// keys — those are not paths and are read no more here than they were
// before.

/// The fixture is Brave's real stanza, verbatim from the machine that found
/// this, because Brave is the app whose detail pane exposed the whole
/// problem.
private func writeInternalJWSFixture(payload: String, to url: URL) throws {
    let envelope: [String: Any] = ["payload": payload, "signatures": []]
    try JSONSerialization.data(withJSONObject: envelope).write(to: url)
}

@Test func homebrew6PackagesCacheIsReadWithItsOwnShape() throws {
    try withTempDirectory { dir in
        let payload = """
        {
          "metadata": { "homebrew_version": "6.0.18" },
          "casks": {
            "brave-browser": {
              "desc": "Web browser focusing on privacy",
              "raw_artifacts": [
                [":app", ["Brave Browser.app"]],
                [":zap", {
                  ":trash": [
                    "~/Library/Application Support/BraveSoftware/Brave-Browser",
                    "~/Library/Caches/com.brave.Browser"
                  ],
                  ":rmdir": ["~/Library/Caches/BraveSoftware"],
                  ":launchctl": ["com.brave.Browser.helper"]
                }]
              ]
            }
          }
        }
        """
        let url = dir.appending(path: "packages.arm64_tahoe.jws.json")
        try writeInternalJWSFixture(payload: payload, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "Brave Browser.app", presence: nil) == [
            homePath("Library/Application Support/BraveSoftware/Brave-Browser"),
            homePath("Library/Caches/BraveSoftware"),
            homePath("Library/Caches/com.brave.Browser"),
        ])
    }
}

/// `:launchctl`, `:pkgutil`, `:script`, `:login_item` and `:kext` are all
/// real `:zap` keys in the shipped cache and none of them names a path. The
/// old reader took only the three path keys; taking them all now would
/// attribute a service label to an app as though it were a file.
@Test func homebrew6NonPathZapKeysAreNotTreatedAsPaths() throws {
    try withTempDirectory { dir in
        let payload = """
        {
          "casks": {
            "example": {
              "raw_artifacts": [
                [":app", ["Example.app"]],
                [":zap", {
                  ":trash": ["~/Library/Caches/com.example"],
                  ":pkgutil": ["com.example.pkg"],
                  ":kext": ["com.example.kext"]
                }]
              ]
            }
          }
        }
        """
        let url = dir.appending(path: "packages.tahoe.jws.json")
        try writeInternalJWSFixture(payload: payload, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "Example.app", presence: nil)
            == [homePath("Library/Caches/com.example")])
    }
}

/// The token is the map key in this format. `declaredApps()` and every
/// "two unrelated casks declare the same path" rule are keyed on it, so a
/// reader that left it empty would collapse every cask into one token and
/// silently defeat those rules.
@Test func homebrew6TokenComesFromTheMapKey() throws {
    try withTempDirectory { dir in
        let payload = """
        {
          "casks": {
            "first-app": { "raw_artifacts": [[":app", ["First.app"]]] },
            "second-app": { "raw_artifacts": [[":app", ["Second.app"]]] }
          }
        }
        """
        let url = dir.appending(path: "packages.tahoe.jws.json")
        try writeInternalJWSFixture(payload: payload, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(Set(index.declaredApps().map(\.token)) == ["first-app", "second-app"])
    }
}

/// A Homebrew 6.0 `:app` artifact is a **three**-element entry whenever the
/// cask renames the bundle on install — 64 of them in the shipped cache, 61
/// casks, `cleanmymac` and `bitcoin-core` among them. The fixture is
/// `cleanmymac`'s real stanza.
///
/// The name that matters is the `:target`: that is what lands in
/// /Applications and what every app-anchored query is keyed on. The first
/// element is the name inside the download, and reading *that* as the app name
/// would be worse than reading nothing — seven of those source names are
/// another cask's real installed name (`Thorium.app` is `thorium`'s,
/// `Android Studio.app` is `android-studio`'s), so this cask's zap paths would
/// be offered under a different product's row.
@Test func aHomebrew6AppArtifactRenamedOnInstallIsReadFromItsTarget() throws {
    try withTempDirectory { dir in
        let payload = """
        {
          "casks": {
            "cleanmymac": {
              "raw_artifacts": [
                [":app", ["CleanMyMac_5.app"], { ":target": "CleanMyMac.app" }],
                [":zap", { ":trash": [
                  "~/Library/Application Support/CleanMyMac_5",
                  "~/Library/Caches/com.macpaw.CleanMyMac5"
                ] }]
              ]
            }
          }
        }
        """
        let url = dir.appending(path: "packages.tahoe.jws.json")
        try writeInternalJWSFixture(payload: payload, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "CleanMyMac.app", presence: nil) == [
            homePath("Library/Application Support/CleanMyMac_5"),
            homePath("Library/Caches/com.macpaw.CleanMyMac5"),
        ])
        // The name inside the download is not an installed bundle name.
        #expect(index.zapPaths(forAppBundleNamed: "CleanMyMac_5.app", presence: nil).isEmpty)
    }
}

/// The legacy cache has the rename form too, in its own spelling: the `app`
/// value is an array whose second element is the options hash, `{"target":
/// "CleanMyMac.app"}`. Verified against `formulae.brew.sh/api/cask.json` —
/// 64 such entries across 61 casks, the same casks the Homebrew 6.0 cache
/// renames, and every one of them shaped `[String, {"target": String}]`.
///
/// The fixture is `cleanmymac`'s real stanza, trimmed. It is the same hazard
/// the Homebrew 6.0 reader answers: keeping the download name and dropping the
/// target offers this cask's zap paths under a bundle name no machine
/// installs, and — for the source names that are another cask's real installed
/// name, `Thorium.app` and `Android Studio.app` among them — under a *rival
/// product's* row.
@Test func aLegacyAppArtifactRenamedOnInstallIsReadFromItsTarget() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "cleanmymac",
            "artifacts": [
              { "app": ["CleanMyMac_5.app", { "target": "CleanMyMac.app" }] },
              { "zap": [ { "trash": [
                "~/Library/Application Support/CleanMyMac_5",
                "~/Library/Caches/com.macpaw.CleanMyMac5"
              ] } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "CleanMyMac.app", presence: nil) == [
            homePath("Library/Application Support/CleanMyMac_5"),
            homePath("Library/Caches/com.macpaw.CleanMyMac5"),
        ])
        // The name inside the download is not an installed bundle name.
        #expect(index.zapPaths(forAppBundleNamed: "CleanMyMac_5.app", presence: nil).isEmpty)
        // And the reading is a complete one, so this cask can still be proved
        // absent when the machine has no bundle by that name.
        #expect(index.declaresApp(forCaskToken: "cleanmymac") == true)
    }
}

/// The legacy twin of `aHomebrew6AppArtifactThisCannotReadWithholdsTheAppAnswer`.
/// A `target` naming a path rather than a bare filename yields no name and
/// reads short — 5 such entries in the published cache, `box-tools` (four
/// bundles under `~/Library/Application Support`) and `ftdi-vcp-driver` — and
/// an options hash carrying no `target` is a shape this cannot read at all.
/// A bundle placed outside an Applications folder is not something the
/// presence sweep enumerates, so a name taken from it would miss for a reason
/// that says nothing about whether the product is here.
@Test func aLegacyAppArtifactThisCannotReadWithholdsTheAppAnswer() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "box-tools",
            "artifacts": [
              { "app": ["Install Box Tools.app/Contents/Resources/Box Edit.app",
                        { "target": "~/Library/Application Support/Box/Box Edit/Box Edit.app" }] },
              { "zap": [ { "trash": "~/Library/Application Support/Box/Box Edit" } ] }
            ]
          },
          {
            "token": "unknown-shape",
            "artifacts": [
              { "app": ["Unknown.app", { "no-target": "x" }] },
              { "zap": [ { "trash": "~/Library/Caches/com.example.unknown" } ] }
            ]
          },
          {
            "token": "plain",
            "artifacts": [
              { "app": ["Plain.app"] },
              { "zap": [ { "trash": "~/Library/Caches/com.example.plain" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.declaresApp(forCaskToken: "box-tools") == nil)
        #expect(index.declaresApp(forCaskToken: "unknown-shape") == nil)
        // The answer that is a finding, so the two withheld above are not
        // vacuous.
        #expect(index.declaresApp(forCaskToken: "plain") == true)
        // Neither unreadable cask leaves a download name behind to be
        // queried under.
        #expect(index.zapPaths(forAppBundleNamed: "Unknown.app", presence: nil).isEmpty)
        #expect(index.zapPaths(forAppBundleNamed: "Plain.app", presence: nil)
            == [homePath("Library/Caches/com.example.plain")])
    }
}

/// `declaresApp` answers `nil`, not `false`, for a cask whose `:app` artifacts
/// this reader could not turn into installed bundle names. "Declares no app"
/// is a finding about the cask; "could not read what it declares" is a fact
/// about this parse, and the two send an identity down different anchors.
///
/// Two `:target` forms fail to yield a name, both from the shipped cache:
/// `box-tools` and `ftdi-vcp-driver` target an explicit path rather than a
/// bundle landing in an Applications folder, so no filename this sweep
/// enumerates could match. An entry shaped in some third way this reader does
/// not know withholds for the same reason.
@Test func aHomebrew6AppArtifactThisCannotReadWithholdsTheAppAnswer() throws {
    try withTempDirectory { dir in
        let payload = """
        {
          "casks": {
            "box-tools": {
              "raw_artifacts": [
                [":app", ["Install Box Tools.app/Contents/Resources/Box Edit.app"],
                         { ":target": "~/Library/Application Support/Box/Box Edit/Box Edit.app" }],
                [":zap", { ":trash": "~/Library/Application Support/Box/Box Edit" }]
              ]
            },
            "unknown-shape": {
              "raw_artifacts": [
                [":app", ["Unknown.app"], "not-an-options-hash"],
                [":zap", { ":trash": "~/Library/Caches/com.example.unknown" }]
              ]
            },
            "plain": {
              "raw_artifacts": [
                [":app", ["Plain.app"]],
                [":zap", { ":trash": "~/Library/Caches/com.example.plain" }]
              ]
            },
            "no-app": {
              "raw_artifacts": [
                [":zap", { ":trash": "~/Library/Caches/com.example.noapp" }]
              ]
            }
          }
        }
        """
        let url = dir.appending(path: "packages.tahoe.jws.json")
        try writeInternalJWSFixture(payload: payload, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.declaresApp(forCaskToken: "box-tools") == nil)
        #expect(index.declaresApp(forCaskToken: "unknown-shape") == nil)

        // The two answers that are findings, so the withheld one above is not
        // simply this accessor having stopped answering.
        #expect(index.declaresApp(forCaskToken: "plain") == true)
        #expect(index.declaresApp(forCaskToken: "no-app") == false)
    }
}

/// The legacy shape's outermost cast has the same hazard. One element of
/// `artifacts` that is not a dict fails the cast for the whole array, so every
/// `app` the cask declares goes unread — and a cask read as declaring nothing
/// is stored as nothing, leaving `declaresApp` to answer "declares no app"
/// from the token simply being missing.
///
/// Zero occurrences in the shipped cache; the rule, not a reading of today's
/// data. `no-app` is the control: a cask whose artifacts were read and hold no
/// `app` still gets the finding.
@Test func aLegacyArtifactsArrayThatCouldNotBeReadWithholdsTheAppAnswer() throws {
    try withTempDirectory { dir in
        let url = dir.appending(path: "cask.json")
        try writeJWSFixture(casks: """
        [ { "token": "half-artifacts", "artifacts": [
              42,
              { "zap": [ { "trash": "~/Library/Caches/com.example.half" } ] } ] },
          { "token": "no-app", "artifacts": [
              { "zap": [ { "trash": "~/Library/Caches/com.example.noapp" } ] } ] } ]
        """, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.declaresApp(forCaskToken: "half-artifacts") == nil)
        #expect(index.declaresApp(forCaskToken: "no-app") == false)
    }
}

/// Both formats, one reader. Homebrew 6 is not universal yet, and a machine
/// that has not run `brew update` since upgrading still has the old file.
@Test func theLegacyCaskCacheShapeStillLoads() throws {
    try withTempDirectory { dir in
        let casks = """
        [ { "token": "legacy", "artifacts": [
            { "app": ["Legacy.app"] },
            { "zap": [ { "trash": "~/Library/Caches/com.legacy" } ] } ] } ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.zapPaths(forAppBundleNamed: "Legacy.app", presence: nil)
            == [homePath("Library/Caches/com.legacy")])
    }
}

/// The real cache on this machine, whatever format it is in. Skips rather
/// than fails where Homebrew is not installed — the same bar
/// `realReceiptsOnThisMachineRoundTripThroughReceiptsAndPaths` sets.
@Test func theRealHomebrewCacheOnThisMachineLoads() throws {
    let candidates = CaskIndex.defaultCacheURLs.filter {
        FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
    // Skips rather than fails where Homebrew is not installed, the same way
    // `anotherUsersHome()` lets the multi-account rules skip on a
    // single-account machine. A fixture cannot stand in here: the whole point
    // is that the shipped file's real shape is what changed underneath us.
    guard !candidates.isEmpty else { return }

    let index = try #require(CaskIndex.loadFromDefaultCache())
    #expect(!index.declaredApps().isEmpty)
}

// MARK: - Bundle filename case

// macOS's default filesystem is case-insensitive, so the casing
// `contentsOfDirectory` reports for an app bundle is whatever the installer
// happened to write, not a fact about the app. Measured here: the mainline
// qBittorrent installs as `/Applications/qbittorrent.app` while the cask
// declaring it spells its `app` artifact `qBittorrent.app`. Comparing those
// exactly asks a question the filesystem itself does not answer.

/// A bundle filename differing from the cask's declared `app` only in case
/// is the same app, and its cask's zap paths must still be found.
@Test func anAppBundleMatchesItsCaskWhenOnlyTheFilenameCaseDiffers() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "c0re100-qbittorrent",
            "artifacts": [
              { "app": ["qBittorrent.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/qBittorrent" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        // Exactly the declared path, not the empty list. An implementation
        // that made the group lookup case-insensitive but left Rule 3's
        // exclusion exact would treat this cask as a stranger to its own app,
        // fold its path into `foreignPaths` and subtract it back out to
        // nothing — the two spellings drifting apart, which is the failure
        // this asserts against rather than merely counting a match.
        #expect(index.zapPaths(forAppBundleNamed: "qbittorrent.app", presence: nil)
            == [homePath("Library/Application Support/qBittorrent")])
    }
}

/// Matching ignores case; reporting does not. The declaring cask's own
/// spelling is what a reader is shown, so it must survive the comparison
/// rather than being flattened by it.
@Test func aCaseInsensitiveMatchStillReportsTheCasksOwnSpelling() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "c0re100-qbittorrent",
            "artifacts": [
              { "app": ["qBittorrent.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/qBittorrent" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        let declaration = try #require(
            index.zapDeclarations(forAppBundleNamed: "qbittorrent.app", presence: nil).first)
        #expect(declaration.appNames == ["qBittorrent.app"])
        #expect(declaration.token == "c0re100-qbittorrent")
    }
}

/// `foreignDeclarations` asks the same "is this cask this app's own?"
/// question from the opposite side, and must answer it the same way — a
/// cask excluded when forming the group must stay excluded here, or an
/// app's own deeper declaration comes back as a stranger's claim on its
/// own directory.
@Test func foreignDeclarationsTreatsACaseDifferingBundleNameAsTheAppsOwn() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "c0re100-qbittorrent",
            "artifacts": [
              { "app": ["qBittorrent.app"] },
              { "zap": [
                  { "trash": "~/Library/Application Support/qBittorrent" },
                  { "trash": "~/Library/Application Support/qBittorrent/Cache" }
              ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.foreignDeclarations(
            below: homePath("Library/Application Support/qBittorrent"),
            ofAppBundleNamed: "qbittorrent.app", presence: nil).isEmpty)
    }
}

// MARK: - Receipt-id patterns

/// The ids that anchor a cask with no `app` artifact live in the `pkgutil`
/// key, and Homebrew allows that key in the `uninstall` stanza as well as
/// in `zap`. Measured across the shipped cache: 268 of the 351 zap-no-app
/// casks declaring an Application Support path carry one in either stanza,
/// against 4 in `zap` alone. Reading only `zap` finds almost none of them.
@Test func receiptPatternsAreReadFromBothTheZapAndUninstallStanzas() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "zap-side",
            "artifacts": [
              { "zap": [ { "pkgutil": "com.example.zapped" } ] }
            ]
          },
          {
            "token": "uninstall-side",
            "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.uninstalled" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Example" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.receiptPatterns(forCaskToken: "zap-side") == ["com.example.zapped"])
        #expect(index.receiptPatterns(forCaskToken: "uninstall-side") == ["com.example.uninstalled"])
        #expect(index.receiptPatterns(forCaskToken: "no-such-token").isEmpty)
    }
}

/// A `pkgutil` value is a regular expression, not a literal. Real
/// stanzas use patterns such as `com\\.microsoft\\.package\\..*`; this
/// code only stores them, and nothing here interprets them. Kept
/// verbatim rather than escaped or normalized on the way in.
@Test func aReceiptPatternIsStoredVerbatimIncludingRegexMetacharacters() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          {
            "token": "patterned",
            "artifacts": [
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.suite\\\\..*" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Suite" } ] }
            ]
          }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.receiptPatterns(forCaskToken: "patterned")
            == ["com\\.example\\.suite\\..*"])
    }
}

/// The Homebrew 6.0 cache spells every stanza key with a leading colon and
/// gives `uninstall` a single dict rather than an array. Both shapes must
/// yield the same patterns, or a machine on one cache layout silently
/// anchors nothing.
@Test func receiptPatternsAreReadFromTheHomebrew6CacheShapeToo() throws {
    try withTempDirectory { dir in
        let casks = """
        { "casks": { "six": { "raw_artifacts": [
              [":uninstall", { ":pkgutil": "com.example.six" }],
              [":zap", { ":trash": "~/Library/Application Support/Six" }]
        ] } } }
        """
        let url = dir.appending(path: "packages.tahoe.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.receiptPatterns(forCaskToken: "six") == ["com.example.six"])
    }
}

// MARK: - Rule 3 against this machine

/// The measured case, reduced to a fixture. `Application Support/Microsoft/
/// EdgeUpdater` is 1.4 GB and is declared by `microsoft-edge` and its beta,
/// canary and dev variants. Only `Microsoft Edge.app` is installed, so the
/// three rivals cannot be evidence of a shared vendor root — there is
/// nothing there to share it with.
@Test func aPathIsReleasedWhenEveryRivalClaimantIsProvablyAbsent() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "microsoft-edge", "artifacts": [
              { "app": ["Microsoft Edge.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft/EdgeUpdater" } ] } ] },
          { "token": "microsoft-edge@beta", "artifacts": [
              { "app": ["Microsoft Edge Beta.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft/EdgeUpdater" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))
        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Microsoft Edge.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        // Refused without the presence context — today's behaviour.
        #expect(index.zapPaths(forAppBundleNamed: "Microsoft Edge.app", presence: nil).isEmpty)

        // Released once the rival is known to be absent.
        #expect(index.zapPaths(forAppBundleNamed: "Microsoft Edge.app", presence: presence)
            == [homePath("Library/Application Support/Microsoft/EdgeUpdater")])
    }
}

/// The refusal still stands when a rival IS installed. `Application Support/
/// Microsoft` is claimed by Word and by Edge; with Edge on the machine, Word
/// must not be handed the shared vendor root.
@Test func aPathStaysRefusedWhileAnyRivalClaimantIsInstalled() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "microsoft-word", "artifacts": [
              { "app": ["Microsoft Word.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft" } ] } ] },
          { "token": "microsoft-edge", "artifacts": [
              { "app": ["Microsoft Edge.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Microsoft" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))
        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Microsoft Word.app", "Microsoft Edge.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(index.zapPaths(forAppBundleNamed: "Microsoft Word.app", presence: presence).isEmpty)
    }
}

/// A rival with no positive presence test keeps refusing even though it is
/// not installed, because nothing could have told us either way. This is the
/// fail-closed rule reaching the behaviour it exists to protect.
@Test func aPathStaysRefusedWhenARivalsPresenceCannotBeDetermined() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "gui-app", "artifacts": [
              { "app": ["Thing.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Thing" } ] } ] },
          { "token": "cli-thing", "artifacts": [
              { "binary": ["thing"] },
              { "zap": [ { "trash": "~/Library/Application Support/Thing" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))
        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Thing.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(index.zapPaths(forAppBundleNamed: "Thing.app", presence: presence).isEmpty)
    }
}

/// `foreignDeclarations` answers the containment question the assembler uses
/// to decide whether a shared root is still retained, and must narrow on the
/// same presence context — otherwise one method releases a path while the
/// other still reports a stranger's claim beneath it.
@Test func foreignDeclarationsIgnoresClaimantsThatAreProvablyAbsent() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "host-app", "artifacts": [
              { "app": ["Host.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Host" } ] } ] },
          { "token": "gone-guest", "artifacts": [
              { "app": ["Gone.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Host/Guest" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))
        let presence = CaskPresence.resolve(
            index: index,
            installedAppFilenames: ["Host.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(!index.foreignDeclarations(
            below: homePath("Library/Application Support/Host"),
            ofAppBundleNamed: "Host.app", presence: nil).isEmpty)
        #expect(index.foreignDeclarations(
            below: homePath("Library/Application Support/Host"),
            ofAppBundleNamed: "Host.app", presence: presence).isEmpty)
    }
}

/// A token-anchored query, for the casks no app-shaped query can reach.
/// Rules 2 and 3 apply identically — the anchor changes, the narrowing does
/// not, or a cask reachable only by token would be held to a weaker standard
/// than one reachable by app.
@Test func aCaskWithNoAppArtifactCanBeQueriedByItsToken() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "auto-update", "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.autoupdate" } ] },
              { "zap": [
                  { "trash": "~/Library/Application Support/AutoUpdate" },
                  { "trash": "~/Library/Application Support/AutoUpdate/Cache" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        // Rule 2 still prefers the descendant over the cask's own ancestor.
        #expect(index.zapDeclarations(forCaskToken: "auto-update", presence: nil).map(\.path)
            == [homePath("Library/Application Support/AutoUpdate/Cache")])
    }
}

/// Rule 3 applies to a token-anchored query too: a path another present
/// cask independently claims is refused, exactly as for an app-anchored one.
@Test func aTokenAnchoredQueryStillRefusesAPathAPresentRivalClaims() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "auto-update", "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.autoupdate" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Shared" } ] } ] },
          { "token": "rival", "artifacts": [
              { "app": ["Rival.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Shared" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))
        let presence = CaskPresence.resolve(
            index: index, installedAppFilenames: ["Rival.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        #expect(index.zapDeclarations(forCaskToken: "auto-update", presence: presence).isEmpty)
    }
}

/// The other direction, for the same anchor. Rule 3's release is what makes
/// the presence narrowing worth having, and it was pinned only through an
/// app-anchored query — so the shared `narrow` covered it while the token
/// anchor's own path to it was untested. A cask reachable only by token
/// must be held to the same standard in both directions, or `narrow`'s
/// release half could be lost for it alone.
///
/// `rival` is the only other claimant of `Shared` and is not on this
/// machine, so nothing is left to share the directory with.
@Test func aTokenAnchoredQueryReleasesAPathOnceEveryRivalIsProvablyAbsent() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "token": "auto-update", "artifacts": [
              { "uninstall": [ { "pkgutil": "com.example.autoupdate" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Shared" } ] } ] },
          { "token": "rival", "artifacts": [
              { "app": ["Rival.app"] },
              { "zap": [ { "trash": "~/Library/Application Support/Shared" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))
        let presence = CaskPresence.resolve(
            index: index, installedAppFilenames: ["Other.app"],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])

        // Refused without the presence context — the catalogue-wide answer.
        #expect(index.zapDeclarations(forCaskToken: "auto-update", presence: nil).isEmpty)

        // Released once the rival is known to be absent.
        #expect(index.zapDeclarations(forCaskToken: "auto-update", presence: presence).map(\.path)
            == [homePath("Library/Application Support/Shared")])
    }
}

/// A legacy-shape cask entry carrying no `token` key is stored under the
/// empty string, and the empty string is never an anchor. Anchoring on it
/// would fuse every untokened cask into one identity — one of them
/// answering "does this cask declare an app" for all of them, their receipt
/// patterns pooled into one anchor, and one of them entering
/// `provablyAbsent` as a proof about all of them. The declarations
/// themselves are kept, so their paths still count as another product's
/// claim under Rule 3.
///
/// The single untokened entry below declares both an `app` artifact and a
/// `pkgutil` receipt pattern, so removing either empty-token guard is
/// caught: the same entry is the wrong answer for `receiptPatterns` and for
/// `declaresApp` alike. A fixture split across two entries carries the same
/// two facts on different rows, which arms both guards only if the queries
/// pool every row — a weaker fixture that depends on behaviour elsewhere.
@Test func anEmptyCaskTokenIsNeverAnAnchor() throws {
    try withTempDirectory { dir in
        let casks = """
        [
          { "artifacts": [
              { "app": ["Untokened One.app"] },
              { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.untokened" } ] },
              { "zap": [ { "trash": "~/Library/Application Support/Untokened" } ] } ] }
        ]
        """
        let url = dir.appending(path: "cask.jws.json")
        try writeJWSFixture(casks: casks, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(!index.allTokens().contains(""))
        #expect(index.zapDeclarations(forCaskToken: "", presence: nil).isEmpty)
        #expect(index.receiptPatterns(forCaskToken: "").isEmpty)
        #expect(index.declaresApp(forCaskToken: "") == false)

        let presence = CaskPresence.resolve(
            index: index, installedAppFilenames: [],
            installedAppFilenamesFullyRead: true,
            receiptPackageIDs: [],
            receiptPackageIDsFullyRead: true,
            caskroomTokens: [])
        #expect(!presence.isProvablyAbsent(""))
    }
}

/// Two entries can carry the same token: the legacy cache is an array with
/// no uniqueness rule, and a duplicate is malformed input this type still
/// has to answer about. A token-anchored query answers for the token, so it
/// answers from every declaration wearing it — the union of their receipt
/// patterns, and "an app is declared" if any of them declares one.
///
/// Reading one of them arbitrarily makes the answer depend on cache order:
/// the same machine, the same cache, a different sort, a different verdict.
/// The two orderings below are the same fixture reversed, and they must
/// agree.
@Test func aTokenCarriedByTwoEntriesIsAnsweredFromBoth() throws {
    let appFirst = """
    [
      { "token": "twinned", "artifacts": [ { "app": ["Twinned.app"] } ] },
      { "token": "twinned", "artifacts": [
          { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.twinned" } ] } ] }
    ]
    """
    let patternsFirst = """
    [
      { "token": "twinned", "artifacts": [
          { "uninstall": [ { "pkgutil": "com\\\\.example\\\\.twinned" } ] } ] },
      { "token": "twinned", "artifacts": [ { "app": ["Twinned.app"] } ] }
    ]
    """

    for casks in [appFirst, patternsFirst] {
        try withTempDirectory { dir in
            let url = dir.appending(path: "cask.jws.json")
            try writeJWSFixture(casks: casks, to: url)
            let index = try #require(CaskIndex.load(from: url))

            #expect(index.declaresApp(forCaskToken: "twinned") == true)
            #expect(index.receiptPatterns(forCaskToken: "twinned")
                == ["com\\.example\\.twinned"])
        }
    }
}

/// The shape actually shipped today has the same hazard as the legacy arm
/// above, in three places rather than one, and carried none of the rule.
/// `raw_artifacts` that is not an array, an element of it that is not an
/// array, and an element whose first member is not an artifact kind were all
/// stepped over in silence, leaving the row's completeness flags standing over
/// a reading that skipped something.
///
/// `declaresApp` is where that costs a path. Answering `false` — "provably
/// declares no app" — over an unread `:app` puts a cask that does declare one
/// onto the token anchor, which shrinks its own-path union and releases a path
/// a sibling variant still lives under. That is the reason this accessor
/// withholds at all, stated in its own doc comment.
///
/// Zero occurrences in the shipped cache: every `raw_artifacts` there is an
/// array of arrays led by a kind string. That cache is remote data, revised
/// without any release of this app, and the legacy arm three functions away
/// already reads all three shapes correctly.
@Test func aHomebrew6ArtifactListThisCannotReadWithholdsTheAppAnswer() throws {
    try withTempDirectory { dir in
        let payload = """
        {
          "casks": {
            "not-an-array": { "raw_artifacts": 42 },
            "bad-element": {
              "raw_artifacts": [
                42,
                [":zap", { ":trash": "~/Library/Caches/com.example.bad" }]
              ]
            },
            "no-kind": {
              "raw_artifacts": [
                [42, ["Nameless.app"]],
                [":zap", { ":trash": "~/Library/Caches/com.example.nokind" }]
              ]
            },
            "no-app": {
              "raw_artifacts": [
                [":zap", { ":trash": "~/Library/Caches/com.example.noapp" }]
              ]
            }
          }
        }
        """
        let url = dir.appending(path: "packages.tahoe.jws.json")
        try writeInternalJWSFixture(payload: payload, to: url)
        let index = try #require(CaskIndex.load(from: url))

        #expect(index.declaresApp(forCaskToken: "not-an-array") == nil)
        #expect(index.declaresApp(forCaskToken: "bad-element") == nil)
        #expect(index.declaresApp(forCaskToken: "no-kind") == nil)

        // The finding this withholding is distinguished from: artifacts that
        // WERE read and hold no `:app` still answer `false`, so the three
        // above are not this accessor having stopped answering.
        #expect(index.declaresApp(forCaskToken: "no-app") == false)
    }
}
