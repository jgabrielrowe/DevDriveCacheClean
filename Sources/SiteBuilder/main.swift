import Foundation
import SiteGen

// Run from the package root: `swift run SiteBuilder [--check]`
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let writer = SiteWriter(sourceRoot: root.appending(path: "Site"),
                        helpRoot: root.appending(path: "Help"))
let output = root.appending(path: "docs")

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--check"] else {
    FileHandle.standardError.write(Data("unknown argument: \(arguments.joined(separator: " "))\n".utf8))
    exit(1)
}

do {
    if arguments == ["--check"] {
        let drift = try writer.drift(against: output)
        guard drift.isEmpty else { throw SiteError.drift(drift) }
        print("site is up to date")
    } else {
        let count = try writer.write(into: output)
        print("wrote \(count) files to docs/")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
