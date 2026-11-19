import XCTest
@testable import PaperKnifeCore

/// From TextEditTests.cs: text that isn't valid Unicode, through the content stream and PDFium's
/// page rewrite alike. The corpus has it through the content stream (edit-text-that-is-not-valid-unicode).
final class TextEditTests: XCTestCase {
    func testReplaceText_WithTextThatIsNotValidUnicode_IsRejected() throws {
        // .NET can't normalize U+FFFE or an unpaired surrogate: comparing such text threw, which
        // would have ended the app. The C# test's unpaired surrogates can't be in a Swift string.
        for contentEditing in [true, false] {
            let session = try openRaw(RawPdf.baseContent, contentEditing: contentEditing)
            defer {
                session.dispose()
            }

            let result = try session.replaceText(0, find(session, "Hello World").objectIndex, "Hello \u{FFFE} again")

            XCTAssertEqual(result.rejection, .unsupportedCharacters, "Content editing: \(contentEditing)")
            XCTAssertEqual(result.message, "This text has characters that aren't valid Unicode: U+FFFE", "Content editing: \(contentEditing)")
            XCTAssertEqual(result.unsupportedCharacters, ["U+FFFE"], "Content editing: \(contentEditing)")
            XCTAssertFalse(session.isModified, "Content editing: \(contentEditing)")
        }
    }

    private func openRaw(_ content: String, contentEditing: Bool = true) throws -> DocumentSession {
        let session = try DocumentSession.fromSnapshot(PdfSnapshot.fromBytes(RawPdf.singlePage(content)))
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
