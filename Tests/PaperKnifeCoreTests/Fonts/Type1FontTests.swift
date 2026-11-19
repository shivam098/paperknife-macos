import XCTest
@testable import PaperKnifeCore

/// The Type 1 tests of TexFontTests.cs that need no document session.
final class Type1FontTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testType1Font_ReadsAProgramFullOfJunkQuickly() throws {
        // Comments full of half-written keys made an earlier reader take time quadratic in their length.
        let (clear, encrypted, trailer) = TexPdf.subset(TexSubset(junk: 2_000_000))
        let data = clear + encrypted + trailer
        let start = Date()

        let font = try XCTUnwrap(Type1Font.fromEmbedded(data, clear.count, encrypted.count))

        XCTAssertNil(font.differenceFrom(TexPdf.full))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testType1Font_TellsHowACraftedSubsetDiffers() throws {
        // The differences ReplaceText_WhenTheSubsetIsNotPartOfPaperKnifesFont_IsRejected reports.
        let cases: [(TexSubset, String?)] = [
            (TexSubset(), nil),
            (TexSubset(replaceGlyph: "o"), "its glyph “o” differs"),
            (TexSubset(stubSubroutineOf: "d"), nil),
        ]
        for (subset, expected) in cases {
            let (clear, encrypted, trailer) = TexPdf.subset(subset)
            let font = try XCTUnwrap(Type1Font.fromEmbedded(clear + encrypted + trailer, clear.count, encrypted.count))
            let difference = font.differenceFrom(TexPdf.full)
            if let expected {
                XCTAssertEqual(difference, expected)
            } else if subset.stubSubroutineOf != nil {
                XCTAssertNotNil(difference)
                XCTAssertTrue(difference?.ordinalHasPrefix("its subroutine ") == true, difference ?? "")
            } else {
                XCTAssertNil(difference)
            }
        }

        // Renderers read a stray token or a repeated glyph in ways PaperKnife doesn't model: it refuses those subsets.
        for subset in [TexSubset(strayToken: true), TexSubset(duplicateGlyph: true)] {
            let (clear, encrypted, trailer) = TexPdf.subset(subset)
            XCTAssertNil(Type1Font.fromEmbedded(clear + encrypted + trailer, clear.count, encrypted.count))
        }
    }
}
