import Foundation

/// Moves an item to the Trash by asking Finder to do it, so macOS authenticates
/// the move.
///
/// `FileManager.trashItem` refuses an item the user does not own, whatever the
/// containing folder allows; Finder performs the same move after a Touch ID or
/// password prompt. Going through Finder means DDCC never holds root, and the
/// app stays recoverable from the Trash.
///
/// A subprocess rather than `NSAppleScript` because `delete` is synchronous and
/// runs off the main thread, where `NSAppleScript` is not safe.
enum FinderTrash {

    /// Distinguishes the two prompts a user can decline, so the UI can say
    /// which one.
    enum Failure: Error, LocalizedError, Equatable {
        case cancelled
        case automationNotPermitted
        case finderReported(String)
        /// Finder exited cleanly but the item is still on disk. A failure, so
        /// a silent no-op is never reported as a removal.
        case stillPresent

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Authentication was cancelled, so nothing was removed."
            case .automationNotPermitted:
                return """
                    DevDriveCacheClean needs permission to control Finder to remove this app. \
                    Grant it in System Settings ▸ Privacy & Security ▸ Automation.
                    """
            case .finderReported(let message):
                return message
            case .stillPresent:
                return "Finder reported success but the app is still in place."
            }
        }
    }

    static func trash(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script(for: url)]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        // Read before waiting: a full pipe buffer deadlocks a process waiting
        // to write while we wait for it to exit.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(decoding: errorData, as: UTF8.self)
        if let failure = failure(forExitCode: process.terminationStatus, stderr: message) {
            throw failure
        }
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            throw Failure.stillPresent
        }
    }

    /// The script Finder is asked to run.
    ///
    /// `POSIX file` takes a string literal, so an unescaped quote or backslash
    /// in the path would end the literal early and hand Finder a different path
    /// than the guard approved. Backslash is escaped first; the other order
    /// would double the backslash it just introduced.
    static func script(for url: URL) -> String {
        let escaped =
            url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Finder\" to delete POSIX file \"\(escaped)\""
    }

    /// Maps `osascript`'s exit onto the two declines, so neither surfaces as an
    /// unexplained error.
    static func failure(forExitCode code: Int32, stderr: String) -> Failure? {
        guard code != 0 else { return nil }
        if stderr.contains("-128") { return .cancelled }
        // -1743 is errAEEventNotPermitted: Automation permission not granted.
        if stderr.contains("-1743") || stderr.contains("Not authorized") {
            return .automationNotPermitted
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .finderReported(
            trimmed.isEmpty ? "Finder could not remove this app." : trimmed)
    }
}
