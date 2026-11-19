import CPDFium
import Foundation
@testable import PaperKnifeCore

/// What the Syntax, Content and Fonts tests share: where the repository's files are, the fonts the
/// app bundle ships (from third_party/), and PDFium's reading of a page's text.
enum SyntaxTestSupport {
    /// The package root, found from this file's path.
    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            let parent = url.deletingLastPathComponent()
            precondition(parent.path != url.path, "The repository root wasn't found.")
            url = parent
        }

        return url
    }()

    /// third_party/'s font folders, in the precedence the app bundle's layout gives them.
    static var fontDirectories: [URL] {
        let thirdParty = repositoryRoot.appendingPathComponent("third_party")
        return ["amsfonts", "cm-super", "lm"].map { thirdParty.appendingPathComponent($0).appendingPathComponent("fonts") }
    }

    /// Points BundledFonts and Encodings at third_party/, which has the files the app bundle ships.
    static func useRepositoryFonts() {
        if BundledFonts.fontDirectories != fontDirectories {
            BundledFonts.fontDirectories = fontDirectories
        }

        let glyphList = repositoryRoot.appendingPathComponent("third_party").appendingPathComponent("agl").appendingPathComponent("glyphlist.txt")
        if Encodings.glyphListURL != glyphList {
            Encodings.glyphListURL = glyphList
        }
    }

    /// The text PDFium extracts from a page, or nil when it can't read the page.
    static func pdfiumText(_ pdf: [UInt8], page index: Int) -> String? {
        FPDF_InitLibrary()
        return pdf.withUnsafeBytes { bytes -> String? in
            guard let document = FPDF_LoadMemDocument64(bytes.baseAddress, bytes.count, nil) else {
                return nil
            }

            defer { FPDF_CloseDocument(document) }
            guard let page = FPDF_LoadPage(document, Int32(index)) else {
                return nil
            }

            defer { FPDF_ClosePage(page) }
            guard let textPage = FPDFText_LoadPage(page) else {
                return nil
            }

            defer { FPDFText_ClosePage(textPage) }
            let count = FPDFText_CountChars(textPage)
            var buffer = [UInt16](repeating: 0, count: Int(max(0, count)) + 1)
            let written = FPDFText_GetText(textPage, 0, count, &buffer)
            return String(units: buffer.prefix(max(0, Int(written) - 1)))
        }
    }
}
