import Testing
import Foundation
@testable import DDCCCore

/// The whole engine's completeness accounting rests on this one distinction.
/// A path that is not there is the normal case — most profile paths do not
/// exist on any given machine — and must never raise a caveat. A path that
/// exists but was refused means bytes the total does not include, and must
/// always raise one.
@Test func absentPathErrorIsClassifiedAsAbsent() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    do {
        _ = try missing.resourceValues(forKeys: [.isDirectoryKey])
        Issue.record("expected reading a nonexistent path to throw")
    } catch {
        #expect(PathAccess.isAbsent(error) == true)
    }
}

@Test func refusedPathErrorIsNotClassifiedAsAbsent() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let locked = try tree.directory("locked")
        try tree.file("locked/inner.bin", byteCount: 16)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: locked, includingPropertiesForKeys: nil, options: [])
            Issue.record("expected listing a chmod-000 directory to throw")
        } catch {
            #expect(PathAccess.isAbsent(error) == false)
        }
    }
}

/// An error nobody anticipated counts as unreadable, not absent. Overstating
/// incompleteness is the safe direction: a caveat that is too cautious is a
/// smaller failure than a total that is silently wrong.
@Test func anUnrecognisedErrorIsNotTreatedAsAbsence() {
    let odd = NSError(domain: "com.example.unknown", code: 999)
    #expect(PathAccess.isAbsent(odd) == false)
}

/// `URL.resourceValues` and `FileManager` do not agree on which spelling of
/// "no such file" they throw, so both are checked.
@Test func aPosixNoSuchFileErrorIsClassifiedAsAbsent() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    #expect(PathAccess.isAbsent(posix) == true)
}

/// Cocoa often wraps the POSIX error rather than translating it.
@Test func aWrappedNoSuchFileErrorIsClassifiedAsAbsent() {
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    let wrapper = NSError(
        domain: "com.example.wrapper", code: 1,
        userInfo: [NSUnderlyingErrorKey: underlying])
    #expect(PathAccess.isAbsent(wrapper) == true)
}
