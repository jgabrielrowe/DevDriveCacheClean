import Foundation
import HelpBookGen

// Argument parsing and file I/O only. Everything else lives in HelpBookGen so
// the tests can call it without shelling out to `swift run`.
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

switch arguments.first {
case "--emit-markdown":
    let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Help/generated")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for page in ReferencePages.all {
        let url = outputDirectory.appending(path: page.filename)
        try page.markdown.write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(url.path)")
    }

case "--build":
    guard arguments.count > 1 else { fail("usage: HelpBookBuilder --build <destination.help>") }
    let writer = BundleWriter(
        pagesDirectory: URL(fileURLWithPath: "Help/pages"),
        generatedDirectory: URL(fileURLWithPath: "Help/generated"),
        styleSheet: URL(fileURLWithPath: "Help/style.css")
    )
    let destination = URL(fileURLWithPath: arguments[1])
    try writer.write(to: destination)
    try HelpIndex.index(bookAt: destination.path)
    print("built \(destination.path)")

case "--list-anchors":
    for anchor in ReferencePages.allAnchors { print(anchor) }

default:
    fail("usage: HelpBookBuilder [--emit-markdown <dir> | --build <destination.help> | --list-anchors]")
}
