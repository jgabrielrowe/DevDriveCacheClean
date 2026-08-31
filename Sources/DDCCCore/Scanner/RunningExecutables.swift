import Darwin
import Foundation

/// The executable path of every process this user can see.
///
/// Used to keep a toolchain version that something is running out of from
/// being offered for deletion. `NSRunningApplication` is no help here: it
/// enumerates GUI applications, and every process that matters for this — a
/// dev server, a watcher, a language server — has no bundle at all.
///
/// Processes belonging to other users return `EPERM` from `proc_pidpath` and
/// are skipped rather than treated as an error. That is a real limit, not a
/// silent one: it can only cause a version to be *offered* that another
/// account is using, which is why the caller retains on other grounds too.
public enum RunningExecutables {

    /// `nil` when the process list could not be enumerated at all, which is
    /// not the same fact as no processes being visible. `proc_listpids`
    /// answers both with zero, and the caller reads a miss against this list
    /// as proof that nothing is running out of a version — so collapsing them
    /// would offer a live interpreter for deletion. A per-process `EPERM` is
    /// different and stays a skip: the enumeration ran, and the doc above says
    /// what that costs.
    public static func current() -> [URL]? {
        var byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return nil }

        // Asked for twice on purpose: processes start and exit between the two
        // calls, so the second call's return is the one that says how many
        // entries were actually written.
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size)
        byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard byteCount > 0 else { return nil }
        let written = Int(byteCount) / MemoryLayout<pid_t>.size

        var paths: [URL] = []
        // `PROC_PIDPATHINFO_MAXSIZE` is a macro and does not survive into
        // Swift; it is 4 * MAXPATHLEN, which is what `proc_pidpath` documents
        // as the required buffer size.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(written) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            paths.append(URL(fileURLWithPath: String(
                decoding: buffer[..<Int(length)], as: UTF8.self)))
        }
        return paths
    }
}
