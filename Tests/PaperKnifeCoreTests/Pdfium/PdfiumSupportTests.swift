import XCTest
@testable import PaperKnifeCore

/// The .NET semantics the PDFium layer adds to Support, checked against what .NET computes.
final class PdfiumSupportTests: XCTestCase {
    func testUtf8_ReplacesEachMaximalSubpartOfAnIllFormedSequence() {
        XCTAssertEqual(Utf8.string([0x41, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80]).units, "A\u{E9}\u{1F600}".units)
        XCTAssertEqual(Utf8.string([0x41, 0xE0, 0x80, 0x42]).units, "A\u{FFFD}\u{FFFD}B".units)
        XCTAssertEqual(Utf8.string([0xF0, 0x90, 0x80]).units, "\u{FFFD}".units)
        XCTAssertEqual(Utf8.string([0xED, 0xA0, 0x80]).units, "\u{FFFD}\u{FFFD}\u{FFFD}".units)
        XCTAssertEqual(Utf8.string([0xC0, 0xAF, 0xF5, 0x41]).units, "\u{FFFD}\u{FFFD}\u{FFFD}A".units)
        XCTAssertEqual(Utf8.string([0xE2, 0x80, 0x41, 0xE2, 0x80, 0x9C]).units, "\u{FFFD}A\u{201C}".units)
    }

    func testMaximumAndMinimum_PropagateNaNAndOrderSignedZeros() {
        XCTAssertTrue(DotNetMath.maximum(Float.nan, 1).isNaN)
        XCTAssertTrue(DotNetMath.maximum(Float(1), .nan).isNaN)
        XCTAssertTrue(DotNetMath.minimum(1.0, Double.nan).isNaN)
        XCTAssertEqual(DotNetMath.maximum(Float(-0.0), 0).sign, .plus)
        XCTAssertEqual(DotNetMath.maximum(Float(0), -0.0).sign, .plus)
        XCTAssertEqual(DotNetMath.minimum(0.0, -0.0).sign, .minus)
        XCTAssertEqual(DotNetMath.minimum(-0.0, 0.0).sign, .minus)
        XCTAssertEqual(DotNetMath.maximum(Float(2), 3), 3)
        XCTAssertEqual(DotNetMath.minimum(2.0, 3.0), 2)
    }

    func testFloatSequenceEqual_TreatsNaNAsEqual() {
        XCTAssertTrue([Float.nan, 1].dotNetSequenceEqual([.nan, 1]))
        XCTAssertTrue([Float(0)].dotNetSequenceEqual([-0.0]))
        XCTAssertFalse([Float(1)].dotNetSequenceEqual([1, 2]))
    }

    func testExceptions_HaveDotNetMessagesAndHierarchy() {
        XCTAssertEqual(
            ArgumentOutOfRangeException("index", "-1", "index ('-1') must be a non-negative value.").message,
            "index ('-1') must be a non-negative value. (Parameter 'index')\nActual value was -1.")
        XCTAssertEqual(
            ArgumentException("Choose at least one page.", "pageIndices").message,
            "Choose at least one page. (Parameter 'pageIndices')")
        XCTAssertEqual(
            ObjectDisposedException(objectName: "PdfPage").message,
            "Cannot access a disposed object.\nObject name: 'PdfPage'.")

        let outOfRange: Error = ArgumentOutOfRangeException("index")
        let disposed: Error = ObjectDisposedException(objectName: nil)
        XCTAssertTrue(outOfRange is ArgumentException)
        XCTAssertTrue(disposed is InvalidOperationException)
        XCTAssertEqual(disposed.localizedDescription, "Cannot access a disposed object.")
    }
}
