import XCTest
@testable import PaperKnifeCore

final class SelfCheckTests: XCTestCase {
    private let thirdParty = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("third_party", isDirectory: true)

    /// The fonts folder as the app bundle has it, linked to the files in third_party.
    func testPassesWithTheFontsTheAppShips() throws {
        let fonts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fonts) }
        for family in ["amsfonts", "cm-super", "lm"] {
            try FileManager.default.createSymbolicLink(
                at: fonts.appendingPathComponent(family), withDestinationURL: thirdParty.appendingPathComponent("\(family)/fonts"))
        }

        try FileManager.default.createSymbolicLink(
            at: fonts.appendingPathComponent("glyphlist.txt"), withDestinationURL: thirdParty.appendingPathComponent("agl/glyphlist.txt"))

        let result = SelfCheck.run(fonts: fonts)
        XCTAssertTrue(result.passed, result.lines.joined(separator: "\n"))
    }

    func testFailsWhenTheFontsAreMissing() {
        let result = SelfCheck.run(fonts: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertFalse(result.passed)
        // The three font folders and the glyph list; PDFium and zlib still pass.
        XCTAssertEqual(result.lines.filter { $0.hasPrefix("FAIL") }.count, 4, result.lines.joined(separator: "\n"))
    }
}
