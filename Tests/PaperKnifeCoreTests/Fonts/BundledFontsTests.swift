import XCTest
@testable import PaperKnifeCore

/// The fonts the app ships (third_party/, which the app bundle's Resources/Fonts holds).
final class BundledFontsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testEveryBundledFontIsReadAnalyzedAndFoundByItsName() throws {
        let thirdParty = SyntaxTestSupport.repositoryRoot.appendingPathComponent("third_party")
        var problems: [String] = []
        for (folder, expected) in [("amsfonts", 90), ("lm", 92), ("cm-super", 409)] {
            let directory = thirdParty.appendingPathComponent(folder).appendingPathComponent("fonts")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "pfb" }
                .sorted { String.ordinalLess($0.lastPathComponent, $1.lastPathComponent) }
            XCTAssertEqual(files.count, expected, folder)
            for url in files {
                let file = "\(folder)/\(url.lastPathComponent)"
                let pfb = [UInt8](try Data(contentsOf: url))
                let segments = Self.segments(pfb)
                guard let cleartext = segments.first, let name = Type1Font.readFontName(cleartext) else {
                    problems.append("\(file): its name can't be read")
                    continue
                }

                // Found by the name in its cleartext, and read from this very file.
                guard let font = BundledFonts.findType1(name) else {
                    problems.append("\(file): \(name) isn't found or can't be read")
                    continue
                }

                if !font.fontName.ordinalEquals(name) || font.program != segments.reduce([], +) || font.length1 != cleartext.count {
                    problems.append("\(file): \(name) is read from another file")
                }

                // Every glyph can be followed, within the budget a subset's comparison has for all its glyphs.
                let budget = CharStringAnalyzer.Budget(4_000_000)
                for (glyph, program) in font.charStrings {
                    guard let uses = CharStringAnalyzer.analyze(program, font.subrs, budget) else {
                        problems.append("\(file): glyph \(glyph) can't be followed")
                        continue
                    }

                    for code in uses.components where Encodings.standardName(code).map({ font.charStrings.contains(key: $0) }) != true {
                        problems.append("\(file): glyph \(glyph) is built from code \(code), which the font lacks")
                    }
                }
            }
        }

        XCTAssertEqual(problems, [], problems.prefix(20).joined(separator: "\n"))
    }

    func testBundledFonts_AreFoundOnlyByTheNameTheirProgramGives() {
        // Latin Modern's lmr10.pfb is LMRoman10-Regular; a file name from a PDF finds nothing.
        XCTAssertNotNil(BundledFonts.findType1("LMRoman10-Regular"))
        XCTAssertNil(BundledFonts.findType1("lmr10"))
        XCTAssertNil(BundledFonts.findType1("../lm/fonts/lmr10.pfb"))
        XCTAssertEqual(BundledFonts.findType1("CMR10")?.fontName, "CMR10")
        XCTAssertEqual(BundledFonts.findType1("SFRM1000")?.fontName, "SFRM1000")
    }

    /// The segments of a PFB file, in order: the cleartext, the encrypted part and the trailer.
    private static func segments(_ pfb: [UInt8]) -> [[UInt8]] {
        var segments: [[UInt8]] = []
        var at = 0
        while at + 6 <= pfb.count && pfb[at] == 0x80 && (pfb[at + 1] == 1 || pfb[at + 1] == 2) {
            let length = Int(pfb[at + 2]) | Int(pfb[at + 3]) << 8 | Int(pfb[at + 4]) << 16 | Int(pfb[at + 5]) << 24
            segments.append(Array(pfb[(at + 6)..<(at + 6 + length)]))
            at += 6 + length
        }

        return segments
    }
}
