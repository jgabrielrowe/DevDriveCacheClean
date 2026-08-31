import Testing
import Foundation
@testable import DDCCCore

/// Group-container claimants are enumerated from the OS's own access grant
/// rather than from a naming convention, so the one property worth pinning
/// is that the entitlement is actually readable in-process, against a known
/// answer rather than merely "did not crash."
///
/// The Affinity suite is the concrete positive control: all three apps share
/// team `6LVTQB9699`, and measured: with `codesign -d
/// --entitlements`, each declares **two** groups under
/// `com.apple.security.application-groups` —
/// `6LVTQB9699.com.seriflabs` and `6LVTQB9699.com.seriflabs.beta`. The
/// first group is the 1.76 GB container this protects; the
/// second (`.beta`) is why the assertion below is the full two-element set
/// rather than a `contains` check, which would have passed even if the
/// reader silently dropped the beta entry.
///
/// Machine-dependent by necessity: it asserts over whichever of the three
/// apps are actually installed here. On a machine with none of them it
/// RECORDS that it verified nothing rather than passing quietly — the
/// failure mode this test exists to avoid is exactly the design's own
/// original draft, which only asserted "did not crash."
///
/// A hosted runner is the one machine where that recording says nothing
/// useful: nobody installs Affinity on a fresh image, so the test would be
/// red on every run forever, and a red that no commit can turn green is a
/// red everyone learns to scroll past. It is skipped there instead, which
/// states the same fact without spending the signal. `GITHUB_ACTIONS`
/// rather than `CI`: the claim is about an image nothing is installed on,
/// not about automation generally — a self-hosted runner on a real Mac
/// should still run this.
@Test(.disabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil,
                "no Affinity apps on a hosted runner"))
func applicationGroupsMatchTheKnownAffinityEntitlement() throws {
    let expected: Set<String> = ["6LVTQB9699.com.seriflabs", "6LVTQB9699.com.seriflabs.beta"]
    let candidates = [
        "/Applications/Affinity Designer 2.app",
        "/Applications/Affinity Photo 2.app",
        "/Applications/Affinity Publisher 2.app",
    ].map { URL(fileURLWithPath: $0) }
    let installed = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !installed.isEmpty else {
        Issue.record("no Affinity apps found on this machine — entitlement reading was not exercised against a known positive case")
        return
    }
    for app in installed {
        #expect(EntitlementReader.applicationGroups(of: app) == expected)
    }
}

/// Machine-independent negative case: a directory with no code signature at
/// all withholds rather than declaring nothing. Measured — this is the input
/// that fails `SecStaticCodeCreateWithPath` (`-67028`), so the signature was
/// never read and there is nothing to report about what the bundle claims.
///
/// The distinction is load-bearing one layer up: `ClaimantIndex.build` counts
/// an app that declares no groups as a claimant of nothing, and doing that to
/// a bundle it merely could not read releases a container the bundle is still
/// using.
@Test func anUnsignedDirectoryWithholdsItsGroups() throws {
    try withTempDirectory { root in
        let fake = try FixtureTree(root: root).directory("Fake.app")
        #expect(EntitlementReader.applicationGroups(of: fake) == nil)
    }
}

/// A path with nothing at all on disk withholds too, rather than crashing —
/// `SecStaticCodeCreateWithPath` is given a path this process never verified
/// exists, and answers `-67068`.
@Test func aNonexistentPathWithholdsItsGroups() {
    let ghost = URL(fileURLWithPath: "/nonexistent/Ghost-\(UUID().uuidString).app")
    #expect(EntitlementReader.applicationGroups(of: ghost) == nil)
}

/// A plain (non-bundle, unsigned) file is a case `SecStaticCodeCreateWithPath`
/// actually *succeeds* on — measured directly: it treats an arbitrary file as
/// valid ad-hoc code with `errSecSuccess`, and its signing information carries
/// `main-executable` and no `entitlements-dict` key.
///
/// So this is the other side of the two tests above, and the control on them:
/// the signature WAS read and names no application groups, which is a finding
/// about the bundle and the common case — 32 of the 46 apps in /Applications
/// on the machine this was measured on. It answers the empty set, not `nil`.
@Test func aPlainFileDeclaresNoGroups() throws {
    try withTempDirectory { root in
        let file = try FixtureTree(root: root).file("NotABundle.app")
        #expect(EntitlementReader.applicationGroups(of: file) == [])
    }
}
