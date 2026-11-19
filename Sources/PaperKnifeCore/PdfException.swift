import CPDFium
import Foundation

public enum PdfErrorCode: String {
    case unknown = "Unknown"
    case invalidFormat = "InvalidFormat"
    case passwordRequired = "PasswordRequired"
    case unsupportedSecurity = "UnsupportedSecurity"
    case pageError = "PageError"
    case operationFailed = "OperationFailed"
    case restricted = "Restricted"
}

/// A PDF couldn't be opened, read or written. `message` is user-facing.
public final class PdfException: DotNetException, @unchecked Sendable {
    public init(_ errorCode: PdfErrorCode, _ message: String) {
        self.errorCode = errorCode
        super.init(message)
    }

    public let errorCode: PdfErrorCode

    /// Must be called while holding `PdfiumLibrary`'s lock, right after the failing call.
    static func fromLastError() -> PdfException {
        switch FPDF_GetLastError() {
        case UInt(FPDF_ERR_FILE):
            return PdfException(.invalidFormat, "The file couldn't be read.")
        case UInt(FPDF_ERR_FORMAT):
            return PdfException(.invalidFormat, "This file isn't a PDF, or it is damaged.")
        case UInt(FPDF_ERR_PASSWORD):
            return PdfException(.passwordRequired, "This PDF is protected. Enter its password to open it.")
        case UInt(FPDF_ERR_SECURITY):
            return PdfException(.unsupportedSecurity, "This PDF uses a security scheme PaperKnife doesn't support.")
        case UInt(FPDF_ERR_PAGE):
            return PdfException(.pageError, "A page in this PDF couldn't be read.")
        default:
            return PdfException(.unknown, "PDFium couldn't process this file.")
        }
    }
}
