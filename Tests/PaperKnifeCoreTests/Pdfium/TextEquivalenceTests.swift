import XCTest
@testable import PaperKnifeCore

/// `TextEquivalence` compares text as a reader sees it, and refuses what .NET's normalization refuses.
final class TextEquivalenceTests: XCTestCase {
    func testAreEquivalent_ComparesTextAsAReaderSeesIt() throws {
        XCTAssertTrue(try TextEquivalence.areEquivalent("\u{2126}", "\u{3A9}")) // OHM SIGN and OMEGA (NFC)
        XCTAssertTrue(try TextEquivalence.areEquivalent("e\u{301}", "\u{E9}"))
        XCTAssertTrue(try TextEquivalence.areEquivalent("a\u{A0}b", "a b")) // space separators
        XCTAssertFalse(try TextEquivalence.areEquivalent("x\u{B2}", "x2")) // compatibility variants look different
        XCTAssertFalse(try TextEquivalence.areEquivalent("a  b", "a b"))
        XCTAssertTrue(try TextEquivalence.areEquivalentIgnoringSpacing(" a \u{2003} b ", "a b"))
        XCTAssertEqual(try TextEquivalence.lost("Hello \u{3A9}!!", "Hello"), [" ", "\u{3A9}", "!"])
    }

    func testNormalize_RefusesWhatDotNetRefuses() {
        XCTAssertThrowsError(try TextEquivalence.areEquivalent("a\u{FFFE}", "a")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }

        // Each char of a surrogate pair is a lone surrogate on its own.
        XCTAssertThrowsError(try TextEquivalence.lost("\u{1F600}", "x")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
        XCTAssertNoThrow(try TextEquivalence.areEquivalent("\u{1F600}", "\u{1F600}"))
    }
}
