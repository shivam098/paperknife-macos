import XCTest
@testable import PaperKnifeCore

final class PdfToolsTests: XCTestCase {
    // Printing allowed; changing, copying and annotating forbidden (PermissionTests.cs). Bit 11
    // ("assemble") is set, which only has a meaning from security handler revision 3.
    private static let noChangesNoCopying: Int32 = -60

    func testMerge_CombinesDocumentsInOrder() throws {
        let merged = try PdfTools.merge([try TestPdfs.numberedPages(2), try TestPdfs.numberedPages(1)])

        XCTAssertEqual(try pageTexts(merged), ["Page 1", "Page 2", "Page 1"])
    }

    func testExtractPages_CopiesSelectedPagesInTheRequestedOrder() throws {
        let extracted = try PdfTools.extractPages(try TestPdfs.numberedPages(3), [2, 0])

        XCTAssertEqual(try pageTexts(extracted), ["Page 3", "Page 1"])
    }

    func testExtractPages_RejectsPagesThatDoNotExist() throws {
        let document = try TestPdfs.numberedPages(1)

        XCTAssertThrowsError(try PdfTools.extractPages(document, [1])) { error in
            XCTAssertTrue(error is ArgumentOutOfRangeException, "\(error)")
        }
    }

    /// From PermissionTests.cs, the one test there that doesn't need a DocumentSession.
    func testPdfTools_RefuseToCopyPagesFromADocumentThatForbidsCopying() throws {
        let restricted = try EncryptedPdf.singlePage(PdfiumFixtures.baseContent, Self.noChangesNoCopying, 3)
        let numbered = try TestPdfs.numberedPages(1)

        XCTAssertThrowsError(try PdfTools.extractPages(restricted, [0])) { error in
            XCTAssertEqual((error as? PdfException)?.errorCode, .restricted, "\(error)")
        }

        XCTAssertThrowsError(try PdfTools.merge([numbered, restricted])) { error in
            XCTAssertEqual((error as? PdfException)?.errorCode, .restricted, "\(error)")
        }
    }

    /// The text of each page's first run, as `DocumentSession.GetTextRuns` gives it: it returns
    /// the page's own runs.
    private func pageTexts(_ snapshot: PdfSnapshot) throws -> [String] {
        let document = try PdfDocument.load(snapshot)
        defer { document.dispose() }
        let count = try document.pageCount
        return try (0..<count).map { try document.getPage($0).getTextRuns()[0].text }
    }
}
