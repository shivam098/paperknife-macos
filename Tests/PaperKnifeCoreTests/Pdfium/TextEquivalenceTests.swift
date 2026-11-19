import XCTest
@testable import PaperKnifeCore

/// `TextEquivalence` compares text as a reader sees it, and text .NET can't normalize as it is.
final class TextEquivalenceTests: XCTestCase {
    func testAreEquivalent_ComparesTextAsAReaderSeesIt() {
        XCTAssertTrue(TextEquivalence.areEquivalent("\u{2126}", "\u{3A9}")) // OHM SIGN and OMEGA (NFC)
        XCTAssertTrue(TextEquivalence.areEquivalent("e\u{301}", "\u{E9}"))
        XCTAssertTrue(TextEquivalence.areEquivalent("a\u{A0}b", "a b")) // space separators
        XCTAssertFalse(TextEquivalence.areEquivalent("x\u{B2}", "x2")) // compatibility variants look different
        XCTAssertFalse(TextEquivalence.areEquivalent("a  b", "a b"))
        XCTAssertTrue(TextEquivalence.areEquivalentIgnoringSpacing(" a \u{2003} b ", "a b"))
        XCTAssertEqual(TextEquivalence.lost("Hello \u{3A9}!!", "Hello"), [" ", "\u{3A9}", "!"])
    }

    func testTextDotNetCantNormalize_ComparesAsItIs() {
        // .NET's Normalize refuses U+FFFE and unpaired surrogates. Comparing such text threw, which
        // would have ended the app; now it compares unnormalized, with space separators as spaces.
        XCTAssertFalse(TextEquivalence.areEquivalent("a\u{FFFE}", "a"))
        XCTAssertTrue(TextEquivalence.areEquivalent("a\u{A0}\u{FFFE}", "a \u{FFFE}"))
        XCTAssertFalse(TextEquivalence.areEquivalent("e\u{301}\u{FFFE}", "\u{E9}\u{FFFE}"))

        // Each char of a surrogate pair is an unpaired surrogate on its own, which the pair contains.
        XCTAssertEqual(TextEquivalence.lost("\u{1F600}", "\u{1F600}"), [])
        XCTAssertEqual(TextEquivalence.lost("\u{1F600}", "x").count, 2)
    }
}