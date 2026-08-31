import Foundation

/// Runs `body` against a fresh temporary directory, removed afterwards.
func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("DDCCTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// Async overload for tests whose body awaits an actor call.
func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("DDCCTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

/// Builds directory trees declaratively inside a fixture root.
struct FixtureTree {
    let root: URL

    /// Creates a directory at a `/`-separated relative path.
    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a file of `byteCount` zero bytes, making parent directories as needed.
    @discardableResult
    func file(_ relativePath: String, byteCount: Int = 0) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: byteCount).write(to: url)
        return url
    }

    /// Creates a symlink at `relativePath` pointing to `target`.
    @discardableResult
    func symlink(_ relativePath: String, to target: URL) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    /// Creates a hard link at `relativePath` pointing at `target`.
    ///
    /// Not `symlink`'s sibling in behaviour: this is a second directory entry
    /// for the same inode, so both names are the file. The sizer has to decide
    /// whether the bytes belong to this tree, which is the whole point of the
    /// fixtures that use it.
    @discardableResult
    func hardLink(_ relativePath: String, to target: URL) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: target, to: url)
        return url
    }
}
