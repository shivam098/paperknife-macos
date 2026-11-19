import XCTest
@testable import PaperKnifeCore

/// The test of ContentEditTests.cs the conformance corpus can't express: saving after undo and
/// redo. The corpus covers the edits themselves (content-*).
final class ContentEditTests: XCTestCase {
    func testUndoAndSave_AfterContentEdit_RestoreAndKeepExactBytes() throws {
        let session = try open(PdfSnapshot.fromBytes(RawPdf.singlePage(RawPdf.baseContent + RawPdf.type3Text)))
        defer {
            session.dispose()
        }

        let original = session.currentSnapshot
        try session.replaceText(0, find(session, "abc").objectIndex, "cab")
        let edited = session.currentSnapshot

        XCTAssertTrue(try session.undo())
        XCTAssertTrue(original === session.currentSnapshot)
        XCTAssertTrue(try session.getTextRuns(0).contains { $0.text == "abc" })
        XCTAssertTrue(try session.redo())

        let name = "paperknife-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")).pdf"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }

        try session.saveAs(path: path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(edited.span))
    }

    private func open(_ snapshot: PdfSnapshot, contentEditing: Bool = true) throws -> DocumentSession {
        let session = try DocumentSession.fromSnapshot(snapshot)
        session.useContentEditing = contentEditing
        return session
    }

    /// The one run on the first page whose text is equivalent to `text`.
    private func find(_ session: DocumentSession, _ text: String) throws -> PdfTextRun {
        let matches = try session.getTextRuns(0).filter { TextEquivalence.areEquivalent($0.text, text) }
        XCTAssertEqual(matches.count, 1, "\(matches.count) runs read “\(text)”.")
        return try XCTUnwrap(matches.first)
    }
}
