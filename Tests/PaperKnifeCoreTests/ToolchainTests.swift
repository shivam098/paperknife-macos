import XCTest
@testable import PaperKnifeCore

final class ToolchainTests: XCTestCase {
    func testPdfiumOpensADocument() {
        let pdf = """
            %PDF-1.4
            1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
            2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >> endobj
            3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >> endobj
            4 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >> endobj
            trailer << /Root 1 0 R >>
            %%EOF
            """

        XCTAssertEqual(Toolchain.pdfiumPageCount(Data(pdf.utf8)), 2)
        XCTAssertNil(Toolchain.pdfiumPageCount(Data("not a PDF".utf8)))
    }

    func testZlibIsLinked() {
        XCTAssertTrue(Toolchain.zlibVersion.hasPrefix("1."))
    }
}
