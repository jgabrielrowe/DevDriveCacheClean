import Foundation

/// Whether this process can read TCC-protected locations.
public enum DiskAccessState: Sendable, Equatable {
    case granted
    case denied
    /// The probe reached no conclusion. Callers show nothing rather than nag.
    case unknown
}

/// Detects Full Disk Access by reading a path only FDA can read.
///
/// There is no API that reports whether an app holds the grant, so the only
/// honest test is to try. The read is injectable so all outcomes are testable
/// without touching real TCC.
public struct DiskAccessProbe: Sendable {

    /// Reads at most one byte from `url`, throwing if it cannot.
    public typealias Read = @Sendable (URL) throws -> Void

    public static let defaultProbePath: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.TCC/TCC.db")

    public static let liveRead: Read = { url in
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
    }

    private let probePath: URL
    private let read: Read

    public init(
        probePath: URL = DiskAccessProbe.defaultProbePath,
        read: @escaping Read = DiskAccessProbe.liveRead
    ) {
        self.probePath = probePath
        self.read = read
    }

    public func state() -> DiskAccessState {
        do {
            try read(probePath)
            return .granted
        } catch {
            return Self.isPermissionDenied(error as NSError) ? .denied : .unknown
        }
    }

    /// Foundation wraps the real failure. Measured: a TCC-denied read
    /// of the probe path throws `(NSCocoaErrorDomain, NSFileWriteNoPermissionError)`
    /// — 513, despite being a read — with POSIX `EPERM` nested under
    /// `NSUnderlyingErrorKey`. Matching only the top-level pair sent every real
    /// denial to `.unknown`, so the banner never appeared.
    private static func isPermissionDenied(_ error: NSError) -> Bool {
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            return true
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                return isPermissionDenied(underlying)
            }
            // Includes "file does not exist". Deliberately not `.denied`.
            return false
        }
    }
}
