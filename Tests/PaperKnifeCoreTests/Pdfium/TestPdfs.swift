import CPDFium
import Foundation
@testable import PaperKnifeCore

/// Builds PDFs with PDFium at test time, so the repository never ships documents it doesn't own.
enum TestPdfs {
    /// What C#'s `Assert.NotEqual` in the fixture reports: PDFium refused a step.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Letter-size pages whose only text is "Page N".
    static func numberedPages(_ count: Int) throws -> PdfSnapshot {
        try PdfiumLibrary.withLock {
            let document = try PdfDocument.createNew()
            defer { document.dispose() }
            let handle = try document.handle
            for i in 0..<count {
                let page = FPDFPage_New(handle, Int32(i), 612, 792)
                try addStandardText(handle, page, "Page \(i + 1)", 72, 700, 24)
                try finishPage(page)
            }

            return try save(document)
        }
    }

    /// One page whose lines draw every character, spaces included, as a text object of its own,
    /// the way PDFs made from web pages by wkhtmltopdf (Qt) do. 12 pt Helvetica.
    static func characterByCharacter(_ lines: (text: String, x: Double, y: Double)...) throws -> PdfSnapshot {
        try PdfiumLibrary.withLock {
            let document = try PdfDocument.createNew()
            defer { document.dispose() }
            let handle = try document.handle
            let page = FPDFPage_New(handle, 0, 612, 792)
            for (text, start, y) in lines {
                var x = start
                for c in text.utf16 {
                    let textObject = try addStandardText(handle, page, String(units: [c]), x, y, 12)
                    var width: Float = 0
                    if FPDFFont_GetGlyphWidth(FPDFTextObj_GetFont(textObject), UInt32(c), 12, &width) == 0 {
                        throw Failure(description: "PDFium has no width for U+\(String(c, radix: 16)).")
                    }

                    x += Double(width)
                }
            }

            try finishPage(page)
            return try save(document)
        }
    }

    /// The document as PDFium saves it, with the creation date and the file identifier it makes up
    /// set to constants of the same length, so the same test document has the same bytes every
    /// time (the conformance corpus stores them).
    private static func save(_ document: PdfDocument) throws -> PdfSnapshot {
        var bytes = Array(try document.save().span)
        let text = Latin1.string(bytes)
        if let id = text.ordinalLastIndexOf("/ID[<") {
            var i = id + 5
            while i < bytes.count && bytes[i] != UInt8(ascii: "]") {
                if isHexDigit(bytes[i]) {
                    bytes[i] = UInt8(ascii: "0")
                }

                i += 1
            }
        }

        if let date = text.ordinalIndexOf("/CreationDate(D:"), text.length >= date + 30,
            bytes[(date + 16)..<(date + 30)].allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            bytes.replaceSubrange((date + 16)..<(date + 30), with: Array("20240101000000".utf8))
        }

        return try PdfSnapshot.fromBytes(bytes)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    @discardableResult
    private static func addStandardText(
        _ document: FPDF_DOCUMENT, _ page: FPDF_PAGE?, _ text: String, _ x: Double, _ y: Double, _ size: Float
    ) throws -> FPDF_PAGEOBJECT? {
        let textObject = FPDFPageObj_NewTextObj(document, "Helvetica", size)
        try setText(textObject, text)
        FPDFPageObj_Transform(textObject, 1, 0, 0, 1, x, y)
        FPDFPage_InsertObject(page, textObject)
        return textObject
    }

    private static func setText(_ textObject: FPDF_PAGEOBJECT?, _ text: String) throws {
        let units = text.units + [0]
        if units.withUnsafeBufferPointer({ FPDFText_SetText(textObject, $0.baseAddress) }) == 0 {
            throw Failure(description: "PDFium couldn't set the text \"\(text)\".")
        }
    }

    private static func finishPage(_ page: FPDF_PAGE?) throws {
        if FPDFPage_GenerateContent(page) == 0 {
            throw Failure(description: "PDFium couldn't generate the page content.")
        }

        FPDF_ClosePage(page)
    }
}
