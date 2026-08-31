import Testing
import Foundation
@testable import DDCCCore

@Test func coreModuleIsImportable() {
    #expect(CleanCategory.allCases.isEmpty == false)
}

@Test func fixtureTreeCreatesNestedFiles() throws {
    try withTempDirectory { root in
        let tree = FixtureTree(root: root)
        let file = try tree.file("a/b/c.txt", byteCount: 128)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
