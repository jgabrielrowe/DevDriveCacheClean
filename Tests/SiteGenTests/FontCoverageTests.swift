import CryptoKit
import Foundation
import Testing
@testable import SiteGen

private func withFontsDirectory(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "fonts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func writeFace(_ bytes: Data, named name: String, in dir: URL) throws -> FontManifest.Face {
    try bytes.write(to: dir.appending(path: name))
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return FontManifest.Face(file: name, sha256: digest, byteCount: bytes.count)
}

@Test func aCodepointNoFaceCarriesIsReported() throws {
    try withFontsDirectory { dir in
        let face = try writeFace(Data("wOF2fake".utf8), named: "A.woff2", in: dir)
        let manifest = FontManifest(codepoints: [0x41], faces: [face])
        #expect(throws: FontError.self) {
            try FontCoverage.verify(manifest: manifest, fontsDirectory: dir, cover: [0x41, 0x2014])
        }
    }
}

@Test func fullCoveragePasses() throws {
    try withFontsDirectory { dir in
        let face = try writeFace(Data("wOF2fake".utf8), named: "A.woff2", in: dir)
        let manifest = FontManifest(codepoints: [0x41, 0x2014], faces: [face])
        try FontCoverage.verify(manifest: manifest, fontsDirectory: dir, cover: [0x41])
    }
}

@Test func aFontReplacedSinceTheManifestWasWrittenIsRejected() throws {
    try withFontsDirectory { dir in
        let face = try writeFace(Data("wOF2fake".utf8), named: "A.woff2", in: dir)
        try Data("wOF2different".utf8).write(to: dir.appending(path: "A.woff2"))
        let manifest = FontManifest(codepoints: [0x41], faces: [face])
        #expect(throws: FontError.self) {
            try FontCoverage.verify(manifest: manifest, fontsDirectory: dir, cover: [0x41])
        }
    }
}

@Test func aFontNamedByTheManifestButAbsentIsRejected() throws {
    try withFontsDirectory { dir in
        let face = FontManifest.Face(file: "Gone.woff2", sha256: "00", byteCount: 1)
        let manifest = FontManifest(codepoints: [0x41], faces: [face])
        #expect(throws: FontError.self) {
            try FontCoverage.verify(manifest: manifest, fontsDirectory: dir, cover: [0x41])
        }
    }
}
