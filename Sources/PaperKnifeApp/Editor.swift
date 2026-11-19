import CoreGraphics
import Foundation
import PaperKnifeCore

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
final class Editor {
    private let session: DocumentSession

    private init(session: DocumentSession) {
        self.session = session
    }

    static func open(path: String, password: String?) throws -> Editor {
        do {
            return Editor(session: try DocumentSession.open(path: path, password: password))
        } catch let error as PdfException where error.errorCode == .passwordRequired {
            throw EditorError.passwordRequired
        }
    }

    /// The file the document was opened from or last saved as.
    var filePath: String? { session.filePath }

    /// The session's state; an empty one once the session is closed, as on Windows.
    var state: SessionState {
        guard let pageCount = try? session.pageCount, let signatureCount = try? session.signatureCount else {
            return SessionState()
        }

        return SessionState(
            pageCount: pageCount, canUndo: session.canUndo, canRedo: session.canRedo,
            isModified: session.isModified, signatureCount: signatureCount)
    }

    func pageSize(_ page: Int) throws -> CGSize {
        let size = try session.getPageSize(page)
        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    func render(_ page: Int, width: Int, height: Int) throws -> PageBitmap {
        let rendered = try session.renderPage(page, width, height)
        return PageBitmap(image: try Self.image(rendered), width: rendered.width, height: rendered.height)
    }

    func textRuns(_ page: Int) throws -> [TextRun] { try session.getTextRuns(page).map(Self.run) }

    /// The text run, or nil when there is none or it can't be read.
    func textRun(_ page: Int, objectIndex: Int) -> TextRun? { (try? session.getTextRun(page, objectIndex)).map(Self.run) }

    /// The text under the point, or nil when there is none or it can't be read.
    func hitTest(_ page: Int, width: Int, height: Int, x: Int, y: Int) -> TextRun? {
        (try? session.hitTestText(page, width, height, x, y)).map(Self.run)
    }

    /// The rectangle in pixels of a page drawn at this size, or nil when it can't be mapped.
    func mapToPixels(_ page: Int, rect: PageRect, width: Int, height: Int) -> CGRect? {
        guard let mapped = try? session.mapToPixels(page, PdfRect(rect.left, rect.bottom, rect.right, rect.top), width, height) else {
            return nil
        }

        return CGRect(x: mapped.x, y: mapped.y, width: mapped.width, height: mapped.height)
    }

    func editBlockers(_ page: Int) throws -> [String] { try session.getTextEditBlockers(page) }

    func replaceText(_ page: Int, objectIndex: Int, text: String) throws -> EditOutcome {
        Self.outcome(try session.replaceText(page, objectIndex, text))
    }

    func rotatePage(_ page: Int, quarterTurns: Int) throws -> EditOutcome { Self.outcome(try session.rotatePage(page, quarterTurns)) }

    func deletePage(_ page: Int) throws -> EditOutcome { Self.outcome(try session.deletePage(page)) }

    func appendDocument(path: String) throws -> EditOutcome { Self.outcome(try session.appendDocument(try PdfSnapshot.fromFile(path))) }

    /// Whether there was an edit to undo; false also when the session can't (it is closed).
    func undo() -> Bool { (try? session.undo()) ?? false }

    /// Whether there was an edit to redo; false also when the session can't (it is closed).
    func redo() -> Bool { (try? session.redo()) ?? false }

    func saveAs(path: String) throws { try session.saveAs(path: path) }

    func close() { session.dispose() }

    private static func run(_ run: PdfTextRun) -> TextRun {
        TextRun(
            pageIndex: run.pageIndex, objectIndex: run.objectIndex, objectCount: run.objectCount, text: run.text,
            bounds: PageRect(left: run.bounds.left, bottom: run.bounds.bottom, right: run.bounds.right, top: run.bounds.top),
            fontName: run.fontName, isFontEmbedded: run.isFontEmbedded, isFontSubset: run.isFontSubset,
            fontSize: run.fontSize, isInvisible: run.isInvisible)
    }

    private static func outcome(_ result: EditResult) -> EditOutcome {
        let status: EditOutcome.Status = switch result.status {
        case .applied: .applied
        case .noChange: .noChange
        case .rejected: .rejected
        }

        return EditOutcome(status: status, message: result.message, warnings: result.warnings, details: result.details, textRun: result.textRun.map(run))
    }

    /// PDFium's BGRA pixels, which are 32-bit little-endian words with alpha first.
    private static func image(_ bitmap: RenderedBitmap) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.stride,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw EditorError.failed("The page couldn't be drawn.")
        }

        return image
    }
}