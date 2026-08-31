import CryptoKit
import Foundation

public struct FontManifest: Codable, Sendable {
    public struct Face: Codable, Sendable {
        public let file: String
        public let sha256: String
        public let byteCount: Int

        public init(file: String, sha256: String, byteCount: Int) {
            self.file = file
            self.sha256 = sha256
            self.byteCount = byteCount
        }
    }

    /// The union of every shipped face's character map — every codepoint at
    /// least one shipped face can render. CSS assigns each element an
    /// explicit font-family (mono, sans, or serif); nothing on this site
    /// picks a face at random, so a character only the mono face carries
    /// (the currency row) is still safe as long as the site only ever asks
    /// the mono face to render it. Subsetting cannot introduce a gap this
    /// check would miss: it only removes glyphs a face already had, so a
    /// face's contribution to the union after subsetting is exactly what it
    /// was asked to keep.
    public let codepoints: [UInt32]
    public let faces: [Face]

    public init(codepoints: [UInt32], faces: [Face]) {
        self.codepoints = codepoints
        self.faces = faces
    }
}

public enum FontError: Error, CustomStringConvertible {
    case uncovered([UInt32])
    case fontMissing(String)
    case fontChanged(String)

    public var description: String {
        switch self {
        case .uncovered(let values):
            let shown = values.sorted().prefix(12).map { value -> String in
                let scalar = UnicodeScalar(value).map(String.init) ?? "?"
                return String(format: "U+%04X (%@)", value, scalar)
            }.joined(separator: ", ")
            let more = values.count > 12 ? " … and \(values.count - 12) more" : ""
            return """
                the site uses characters the shipped fonts do not carry: \(shown)\(more)
                re-subset the upstream faces named in Site/assets/fonts/OFL-*.txt,
                or change the copy to stay inside what they carry
                """
        case .fontMissing(let file):
            return "Site/fonts-manifest.json names \(file), which is not in Site/assets/fonts"
        case .fontChanged(let file):
            return """
                Site/assets/fonts/\(file) does not match Site/fonts-manifest.json
                rehash the shipped faces into the manifest
                """
        }
    }
}

public enum FontCoverage {
    public static func verify(
        manifest: FontManifest, fontsDirectory: URL, cover required: Set<UInt32>
    ) throws {
        for face in manifest.faces {
            let url = fontsDirectory.appending(path: face.file)
            guard let bytes = try? Data(contentsOf: url) else {
                throw FontError.fontMissing(face.file)
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == face.byteCount, digest == face.sha256 else {
                throw FontError.fontChanged(face.file)
            }
        }
        let covered = Set(manifest.codepoints)
        let missing = required.subtracting(covered)
        guard missing.isEmpty else { throw FontError.uncovered(Array(missing)) }
    }
}
