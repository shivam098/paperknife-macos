import CPDFium
import CZlib
import Foundation

/// Proves the toolchain works: PDFium and zlib link, load and run. The engine itself is a port of
/// PaperKnife for Windows' engine (see docs/PORTING.md).
enum Toolchain {
    private static let initialized: Void = FPDF_InitLibrary()

    /// The page count of a PDF, or nil when PDFium can't open it.
    static func pdfiumPageCount(_ data: Data) -> Int? {
        _ = initialized
        return data.withUnsafeBytes { bytes -> Int? in
            guard let document = FPDF_LoadMemDocument64(bytes.baseAddress, bytes.count, nil) else {
                return nil
            }

            defer { FPDF_CloseDocument(document) }
            return Int(FPDF_GetPageCount(document))
        }
    }

    /// The version of the zlib the app links.
    static var zlibVersion: String { String(cString: CZlib.zlibVersion()) }
}
