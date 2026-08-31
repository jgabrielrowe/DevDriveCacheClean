import Foundation

/// Whether a filesystem error means "there is nothing here" or "I was refused".
///
/// This distinction is load-bearing across the whole engine. Absence is the
/// ordinary case: most profile paths do not exist on any given machine, and if
/// absence raised a completeness caveat, every scan everywhere would report
/// dozens of unreadable folders and users would learn to ignore the warning
/// that matters. A refusal is the opposite: bytes exist that the reported total
/// does not include, and the total must say so.
///
/// `SizeCalculator` already stated half of this rule in prose — "absence is not
/// a denial" — but had no way to act on it, because `try?` throws the error
/// away. This is that way.
public enum PathAccess {

    /// True when `error` means the path is not there.
    ///
    /// Checked against both the Cocoa and the POSIX spelling, because
    /// `URL.resourceValues` and `FileManager` do not agree on which they
    /// throw, and against one level of `NSUnderlyingErrorKey`, because Cocoa
    /// frequently wraps the POSIX error rather than translating it. One level
    /// only — deliberately not recursive, so a self-referential `userInfo`
    /// cannot spin.
    ///
    /// Anything unrecognised is **not** absence. An error this function does
    /// not understand becomes a counted unreadable path, which overstates
    /// incompleteness. That is the safe direction: a caveat that is too
    /// cautious is a smaller failure than a total that is confidently wrong.
    public static func isAbsent(_ error: Error) -> Bool {
        let nsError = error as NSError
        if isAbsentCode(nsError) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isAbsentCode(underlying)
        }
        return false
    }

    private static func isAbsentCode(_ error: NSError) -> Bool {
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOENT)
        default:
            return false
        }
    }
}
