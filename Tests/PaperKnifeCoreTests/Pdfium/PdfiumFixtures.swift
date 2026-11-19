@testable import PaperKnifeCore

/// Hand-written single-page PDFs (Latin-1), written exactly as PaperKnife for Windows' tests write
/// them (`RawPdf.SinglePage`, with the same shared fonts and shading). Every page has these fonts:
/// - `/F1`: Helvetica.
/// - `/F2`: Helvetica in which code 66 also draws "A", with a wider advance (1000) than code 65 (667).
/// - `/F3`: a Type 3 font whose glyphs "a", "b" and "c" are boxes 500, 600 and 700 units wide.
enum PdfiumFixtures {
    static let baseContent =
        "BT /F1 24 Tf 72 700 Td (Hello World) Tj ET\n"
        + "BT /F1 12 Tf 72 660 Td (This line must not move) Tj ET\n"
        + "0.86 0.16 0.16 rg 72 500 200 100 re f\n"

    private static let shared: [String] = [
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [300 0 500 0] /Extend [true true] "
            + "/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 65 /LastChar 68 /Widths [667 1000 722 722] "
            + "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [66 /A] >> >>",
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 700 700] /FontMatrix [0.001 0 0 0.001 0 0] "
            + "/CharProcs << /a 7 0 R /b 8 0 R /c 9 0 R >> /Encoding << /Type /Encoding /Differences [97 /a /b /c] >> "
            + "/FirstChar 97 /LastChar 99 /Widths [500 600 700] /ToUnicode 10 0 R /Resources << >> >>",
        stream("500 0 0 0 450 700 d1 0 0 450 700 re f"),
        stream("600 0 0 0 550 700 d1 0 0 550 350 re f"),
        stream("700 0 0 0 650 700 d1 0 350 650 350 re f"),
        stream(
            "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /T3 def /CMapType 2 def\n"
                + "1 begincodespacerange <00> <FF> endcodespacerange\n1 beginbfrange <61> <63> <0061> endbfrange\n"
                + "endcmap CMapName currentdict /CMap defineresource pop end end"),
    ]

    /// One page drawing `content`, with a cross-reference table.
    static func singlePage(_ content: String) throws -> PdfSnapshot {
        // Objects 1 and 2 are the catalog and page tree; 3 to 10 are shared; the page and its content follow.
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        objects.append(contentsOf: shared)
        let pageNumber = objects.count + 1
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(pageNumber + 1) 0 R "
                + "/Resources << /Font << /F1 3 0 R /F2 5 0 R /F3 6 0 R >> /Shading << /Sh1 4 0 R >> >> >>")
        objects.append(stream(content))
        objects[1] = "<< /Type /Pages /Kids [\(pageNumber) 0 R] /Count 1 >>"
        return try writeWithTable(objects)
    }

    /// C#'s `$"{value:D10}"`.
    static func d10(_ value: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 10 - digits.count)) + digits
    }

    private static func stream(_ data: String) -> String { "<< /Length \(Latin1.bytes(data).count) >>\nstream\n\(data)\nendstream" }

    /// Writes numbered objects (the first is the catalog) with a cross-reference table.
    private static func writeWithTable(_ objects: [String]) throws -> PdfSnapshot {
        var pdf = "%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n"
        var offsets: [Int] = []
        for i in 0..<objects.count {
            offsets.append(pdf.length)
            pdf += "\(i + 1) 0 obj\n\(objects[i])\nendobj\n"
        }

        let xref = pdf.length
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += "\(d10(offset)) 00000 n \n"
        }

        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return try PdfSnapshot.fromBytes(Latin1.bytes(pdf))
    }
}
