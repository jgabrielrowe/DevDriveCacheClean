import Testing
import Foundation
@testable import DDCCCore

private let probeURL = URL(fileURLWithPath: "/tmp/ddcc-probe")

private func probe(_ read: @escaping DiskAccessProbe.Read) -> DiskAccessProbe {
    DiskAccessProbe(probePath: probeURL, read: read)
}

@Test func readSucceedingMeansGranted() {
    #expect(probe { _ in }.state() == .granted)
}

@Test func cocoaPermissionErrorMeansDenied() {
    let denied = probe { _ in
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    }
    #expect(denied.state() == .denied)
}

@Test func posixPermissionErrorMeansDenied() {
    let denied = probe { _ in
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    }
    #expect(denied.state() == .denied)
}

/// The load-bearing one. A missing probe path must NOT read as denial, or a
/// future macOS that moves TCC.db would nag a fully-authorised machine forever.
@Test func missingProbePathMeansUnknownNotDenied() {
    let missing = probe { _ in
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    }
    #expect(missing.state() == .unknown)
}

@Test func unrecognisedErrorMeansUnknown() {
    let strange = probe { _ in throw NSError(domain: "Unrecognised", code: 42) }
    #expect(strange.state() == .unknown)
}

/// Pins that the configured path is the one actually read. Without this, a
/// probe that ignored `probePath` and hardcoded a path would pass every test above.
@Test func probeReadsTheConfiguredPath() {
    final class Box: @unchecked Sendable { var url: URL? }
    let box = Box()
    _ = DiskAccessProbe(probePath: probeURL, read: { url in box.url = url }).state()
    #expect(box.url == probeURL)
}

@Test func nestedPermissionErrorMeansDenied() {
    let wrapped = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteNoPermissionError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
    )
    #expect(probe { _ in throw wrapped }.state() == .denied)
}

@Test func nestedMissingFileStillMeansUnknown() {
    let wrapped = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadNoSuchFileError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]
    )
    #expect(probe { _ in throw wrapped }.state() == .unknown)
}

/// The layer where the mistake was actually made. Runs the REAL read against the
/// REAL path: whatever the answer, `.unknown` means the mapping does not match
/// what Foundation throws. Disabled only when the probe path is genuinely absent.
@Test(.enabled(if: FileManager.default.fileExists(
    atPath: DiskAccessProbe.defaultProbePath.path(percentEncoded: false))))
func liveProbeIsNeverUnknown() {
    #expect(DiskAccessProbe().state() != .unknown)
}
