import XCTest
@testable import PaperKnifeCore

/// DocumentTests.cs, through `PdfDocument` and `PdfPage`: `DocumentSession`'s `GetTextRuns`,
/// `RenderPage`, `HitTestText` and `MapToPixels` hand these calls to the page as they are.
final class PdfDocumentTests: XCTestCase {
    func testLoad_RejectsDataThatIsNotPdf() throws {
        let snapshot = try PdfSnapshot.fromBytes(Array("definitely not a pdf".utf8))

        XCTAssertThrowsError(try PdfDocument.load(snapshot)) { error in
            XCTAssertEqual((error as? PdfException)?.errorCode, .invalidFormat, "\(error)")
        }
    }

    func testTextRuns_DescribeTextFontAndPosition() throws {
        let document = try PdfDocument.load(try PdfiumFixtures.singlePage(PdfiumFixtures.baseContent))
        defer { document.dispose() }

        let runs = try document.getPage(0).getTextRuns()

        XCTAssertEqual(runs.map { $0.text }, ["Hello World", "This line must not move"])
        let hello = runs[0]
        XCTAssertEqual(hello.fontName, "Helvetica")
        XCTAssertFalse(hello.isFontEmbedded)
        XCTAssertFalse(hello.isInvisible)
        XCTAssertEqual(hello.fontSize, 24, accuracy: 0.01)
        XCTAssertTrue((71...74).contains(hello.bounds.left), "\(hello.bounds)")
        XCTAssertTrue((690...701).contains(hello.bounds.bottom), "\(hello.bounds)")
    }

    func testRenderPage_DrawsContentOnWhite() throws {
        let document = try PdfDocument.load(try PdfiumFixtures.singlePage(PdfiumFixtures.baseContent))
        defer { document.dispose() }

        let bitmap = try document.getPage(0).render(612, 792)

        let (r, g, b) = pixel(bitmap, 172, 792 - 550)
        XCTAssertTrue((210...225).contains(r), "\(r)")
        XCTAssertTrue((35...47).contains(g), "\(g)")
        XCTAssertTrue((35...47).contains(b), "\(b)")
        XCTAssertTrue(pixel(bitmap, 500, 100) == (255, 255, 255))
    }

    func testHitTestText_FindsTheRunUnderAPixel() throws {
        let document = try PdfDocument.load(try PdfiumFixtures.singlePage(PdfiumFixtures.baseContent))
        defer { document.dispose() }
        let page = try document.getPage(0)

        let hit = try page.hitTestText(612, 792, 100, 792 - 708)

        XCTAssertEqual(hit?.text, "Hello World")
        let bounds = try XCTUnwrap(hit).bounds
        XCTAssertTrue(try page.mapToPixels(bounds, 612, 792).contains(100, 792 - 708))
        XCTAssertNil(try page.hitTestText(612, 792, 500, 50))
    }

    func testDisposedDocument_RefusesCallsAsCSharpDoes() throws {
        let document = try PdfDocument.load(try PdfiumFixtures.singlePage(PdfiumFixtures.baseContent))
        let page = try document.getPage(0)
        document.dispose()

        XCTAssertThrowsError(try document.pageCount) { XCTAssertTrue($0 is ObjectDisposedException, "\($0)") }
        XCTAssertThrowsError(try page.getTextRuns()) { XCTAssertTrue($0 is ObjectDisposedException, "\($0)") }
        XCTAssertThrowsError(try document.getPage(-1)) { XCTAssertTrue($0 is ArgumentOutOfRangeException, "\($0)") }
    }

    private func pixel(_ bitmap: RenderedBitmap, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * bitmap.stride) + (x * 4)
        return (Int(bitmap.pixels[i + 2]), Int(bitmap.pixels[i + 1]), Int(bitmap.pixels[i]))
    }
}
