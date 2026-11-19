import XCTest
@testable import PaperKnifeCore

/// From TextRunTests.cs: text drawn one character per text object, as in PDFs made from web pages
/// by wkhtmltopdf, read through `PdfPage` (`DocumentSession` hands these calls to the page), and
/// the plans of run edits.
final class TextLayoutTests: XCTestCase {
    func testTextRuns_JoinCharactersDrawnOneByOneIntoLinesAndCells() throws {
        let document = try PdfDocument.load(try openInvoice())
        defer { document.dispose() }
        let page = try document.getPage(0)

        let runs = try page.getTextRuns()
        let hit = try page.hitTestText(612, 792, 80, 792 - 704)

        XCTAssertEqual(runs.map { $0.text }, ["Invoice 2024", "$1,250.00", "Total due"])
        for run in runs {
            XCTAssertEqual(run.text.length, run.objectCount) // spaces are objects too
        }

        XCTAssertEqual(hit?.text, "Invoice 2024")
    }

    func testTextRuns_KeepTextOfAnotherColorApart() throws {
        let document = try PdfDocument.load(try PdfiumFixtures.singlePage(
            "BT /F1 12 Tf 72 600 Td (A) Tj 8.004 0 Td (B) Tj 8.004 0 Td 1 0 0 rg (C) Tj ET\n"))
        defer { document.dispose() }

        XCTAssertEqual(try document.getPage(0).getTextRuns().map { $0.text }, ["AB", "C"])
    }

    func testPlan_ChangesTheFewestObjects() throws {
        let cases: [(pieces: String, separators: String, newText: String, first: Int, last: Int, replacement: String)] = [
            ("₹| |1|1|6|8|8", "", "₹ 12688", 3, 3, "2"),
            ("I|n|v|o|i|c|e| |2|0|2|4", "", "Invoice No. 2024", 7, 7, " No. "), // typing after a space joins the space
            ("T|o|t|a|l| |d|u|e", "", "Total", 5, 8, ""), // the word and the space before it go
            ("Single|Pvt|room", " | ", "Single room", 1, 2, "room"), // one object per word, gaps between
            ("t|r|u|s|t|e|d| ", "", "trusty", 5, 6, "y"), // trailing whitespace stays as it is
        ]

        for c in cases {
            let texts = c.pieces.split(onUnit: 0x7C)
            let gaps = c.separators.length > 0 ? c.separators.split(onUnit: 0x7C) : [String](repeating: "", count: texts.count - 1)

            let edit = try TextRunEdit.plan(texts, gaps, c.newText)

            XCTAssertEqual(edit, TextRunEdit(c.first, c.last, c.replacement), c.pieces)
        }
    }

    func testPlan_RefusesARunWithoutObjects() {
        XCTAssertThrowsError(try TextRunEdit.plan([], [], "x")) { XCTAssertTrue($0 is ArgumentOutOfRangeException, "\($0)") }
    }

    private func openInvoice() throws -> PdfSnapshot {
        try TestPdfs.characterByCharacter(("Invoice 2024", 72, 700), ("$1,250.00", 400, 700), ("Total due", 72, 650))
    }
}
