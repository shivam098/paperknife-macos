import CoreGraphics
import Foundation

/// The state of a document session, copied when a command finishes, as PaperKnife for Windows
/// copies it, so views never read the session while the engine works.
struct SessionState: Equatable {
    var pageCount = 0
    var canUndo = false
    var canRedo = false
    var isModified = false
    var signatureCount = 0
}

/// A rectangle in PDF page space: points, origin at the bottom-left, y pointing up (the engine's
/// PdfRect).
struct PageRect: Equatable {
    var left: Float
    var bottom: Float
    var right: Float
    var top: Float

    func inflated(by amount: Float) -> PageRect {
        PageRect(left: left - amount, bottom: bottom - amount, right: right + amount, top: top + amount)
    }
}

/// A piece of text PaperKnife edits as one: usually a line or a table cell (the engine's PdfTextRun).
struct TextRun: Equatable {
    var pageIndex: Int
    var objectIndex: Int
    var objectCount: Int
    var text: String
    var bounds: PageRect
    var fontName: String
    var isFontEmbedded: Bool
    var isFontSubset: Bool
    var fontSize: Float
    var isInvisible: Bool
}

/// The outcome of an edit or page command (the engine's EditResult). A refused command leaves
/// the document exactly as it was.
struct EditOutcome {
    enum Status {
        case applied
        case noChange
        case rejected
    }

    var status: Status
    var message: String
    var warnings: [String]
    var details: [String]
    var textRun: TextRun?
}

enum EditorError: Error {
    case passwordRequired
    case failed(String)

    /// The message to show for any error an engine call throws.
    static func message(of error: Error) -> String {
        switch error {
        case EditorError.failed(let message):
            return message
        case EditorError.passwordRequired:
            return "The file is protected with a password."
        default:
            return error.localizedDescription
        }
    }
}

/// A page drawn for the screen.
struct PageBitmap {
    var image: CGImage
    var width: Int
    var height: Int
}

/// PaperKnife's engine as the app uses it: a DocumentSession, ported from PaperKnife for Windows.
/// Calls can take long, so EditorModel makes them on its engine queue, one at a time.
///
/// Until the port is merged, opening a document fails with a message, so the app can be built
/// and its window checked.
final class Editor {
    let filePath: String?

    private init(filePath: String?) {
        self.filePath = filePath
    }

    static func open(path: String, password: String?) throws -> Editor {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    var state: SessionState { SessionState() }

    func pageSize(_ page: Int) -> CGSize { .zero }

    func render(_ page: Int, width: Int, height: Int) throws -> PageBitmap {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    func textRuns(_ page: Int) -> [TextRun] { [] }

    func textRun(_ page: Int, objectIndex: Int) -> TextRun? { nil }

    func hitTest(_ page: Int, width: Int, height: Int, x: Int, y: Int) -> TextRun? { nil }

    /// The rectangle in pixels of a page drawn at this size, or nil when it can't be mapped.
    func mapToPixels(_ page: Int, rect: PageRect, width: Int, height: Int) -> CGRect? { nil }

    func editBlockers(_ page: Int) -> [String] { [] }

    func replaceText(_ page: Int, objectIndex: Int, text: String) throws -> EditOutcome {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    func rotatePage(_ page: Int, quarterTurns: Int) throws -> EditOutcome {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    func deletePage(_ page: Int) throws -> EditOutcome {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    func appendDocument(path: String) throws -> EditOutcome {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    func undo() -> Bool { false }

    func redo() -> Bool { false }

    func saveAs(path: String) throws {
        throw EditorError.failed("This build of PaperKnife doesn't include its editing engine yet.")
    }

    func close() {}
}
