import CPDFium
import Foundation

/// Checks that PaperKnife works where it is installed: PDFium loads and reads a document, zlib
/// links, and the fonts PaperKnife draws new letters with are where the app looks for them.
/// `PaperKnife --self-check` runs it without opening a window; CI runs that on the packaged app,
/// on Apple silicon and on Intel, before a release is published.
public enum SelfCheck {
    /// One line per check, and whether all of them passed.
    /// - Parameter fonts: The folder of the bundled fonts: `amsfonts`, `cm-super` and `lm` folders
    ///   of `.pfb` files, and `glyphlist.txt`.
    public static func run(fonts: URL) -> (lines: [String], passed: Bool) {
        var lines: [String] = []
        var passed = true
        func check(_ ok: Bool, _ line: String) {
            lines.append((ok ? "ok    " : "FAIL  ") + line)
            passed = passed && ok
        }

        let pages = Toolchain.pdfiumPageCount(minimalPdf)
        check(pages == 1, "PDFium reads a one-page document (pages: \(pages.map(String.init) ?? "none, it can't open it"))")
        lines.append("      PDFium is loaded from \(pdfiumPath)")
        check(!Toolchain.zlibVersion.isEmpty, "zlib \(Toolchain.zlibVersion)")

        for (family, sample) in [("amsfonts", "cmr10.pfb"), ("cm-super", "sfrm1000.pfb"), ("lm", "lmr10.pfb")] {
            let folder = fonts.appendingPathComponent(family, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let count = files.filter { $0.hasSuffix(".pfb") }.count
            check(files.contains(sample), "\(count) \(family) fonts, \(sample) among them, in \(folder.path)")
        }

        let glyphList = fonts.appendingPathComponent("glyphlist.txt")
        let entries = (try? String(contentsOf: glyphList, encoding: .utf8))?.split(whereSeparator: \.isNewline) ?? []
        check(entries.contains("A;0041"), "The Adobe Glyph List (\(entries.count) lines) in \(glyphList.path)")
        return (lines, passed)
    }

    /// The file PDFium's code was loaded from.
    private static var pdfiumPath: String {
        let function: @convention(c) () -> Void = FPDF_InitLibrary
        var info = Dl_info()
        guard dladdr(unsafeBitCast(function, to: UnsafeRawPointer.self), &info) != 0, let name = info.dli_fname else {
            return "(unknown)"
        }

        return String(cString: name)
    }

    /// A PDF of one empty page, with a correct cross-reference table.
    private static var minimalPdf: Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }

        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010ld 00000 n \n", offset)
        }

        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
