@testable import PaperKnifeCore

/// Hand-written PDFs (Latin-1) for content and file structures PDFium can't create itself, such as
/// inline images, shadings, character spacing, Type 3 fonts and cross-reference streams.
/// Every page has these fonts:
/// - `/F1`: Helvetica.
/// - `/F2`: Helvetica in which code 66 also draws "A", with a wider advance (1000) than code 65
///   (667), so a glyph's Unicode value doesn't tell its width.
/// - `/F3`: a Type 3 font whose glyphs "a", "b" and "c" are boxes 500, 600 and 700 units wide.
enum RawPdf {
    static let baseContent =
        "BT /F1 24 Tf 72 700 Td (Hello World) Tj ET\n" +
        "BT /F1 12 Tf 72 660 Td (This line must not move) Tj ET\n" +
        "0.86 0.16 0.16 rg 72 500 200 100 re f\n"

    static let shadedArea = "q 300 500 200 100 re W n /Sh1 sh Q\n"

    static let inlineImage =
        "q 60 0 0 60 400 300 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID " +
        "\u{00FF}\u{0000}\u{0000}\u{0000}\u{00FF}\u{0000}\u{0000}\u{0000}\u{00FF}\u{00FF}\u{00FF}\u{0000}\nEI Q\n"

    static let characterSpacing = "BT /F1 14 Tf 4 Tc 72 300 Td (Spaced out letters) Tj ET\n"

    static let kernedText = "BT /F1 18 Tf 72 250 Td [(Ke) -300 (rned text)] TJ ET\n"

    static let type3Text = "BT /F3 24 Tf 72 400 Td (abc) Tj ET\n"

    /// "ab ca" set the way TeX sets text: kerning between a and b, and a gap instead of a space.
    static let gappedText = "BT /F3 24 Tf 72 400 Td [(a) 30 (b) -400 (ca)] TJ ET\n"

    private static let shared: [String] = [
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [300 0 500 0] /Extend [true true] " +
            "/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 65 /LastChar 68 /Widths [667 1000 722 722] " +
            "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [66 /A] >> >>",
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 700 700] /FontMatrix [0.001 0 0 0.001 0 0] " +
            "/CharProcs << /a 7 0 R /b 8 0 R /c 9 0 R >> /Encoding << /Type /Encoding /Differences [97 /a /b /c] >> " +
            "/FirstChar 97 /LastChar 99 /Widths [500 600 700] /ToUnicode 10 0 R /Resources << >> >>",
        stream("500 0 0 0 450 700 d1 0 0 450 700 re f"),
        stream("600 0 0 0 550 700 d1 0 0 550 350 re f"),
        stream("700 0 0 0 650 700 d1 0 350 650 350 re f"),
        stream("/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /T3 def /CMapType 2 def\n" +
            "1 begincodespacerange <00> <FF> endcodespacerange\n1 beginbfrange <61> <63> <0061> endbfrange\n" +
            "endcmap CMapName currentdict /CMap defineresource pop end end"),
    ]

    /// One page drawing `content`, with a cross-reference table.
    static func singlePage(_ content: String) -> [UInt8] { build([[content]]) }

    /// A document whose pages draw the given content streams. With `shareContent`, the second page
    /// draws the first page's first stream instead of its own. With `useObjectStreams`, dictionaries
    /// are stored in an object stream and the cross-reference data in a compressed stream with a
    /// PNG predictor.
    static func build(_ pages: [[String]], shareContent: Bool = false, useObjectStreams: Bool = false) -> [UInt8] {
        // Objects 1 and 2 are the catalog and page tree; 3 to 10 are shared; pages follow.
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        objects += shared
        var kids: [Int] = []
        var firstStream = 0
        for contents in pages {
            let pageNumber = objects.count + 1
            kids.append(pageNumber)
            objects.append("")
            var streams: [Int] = []
            for content in contents {
                objects.append(stream(content))
                streams.append(objects.count)
            }

            if firstStream == 0 {
                firstStream = streams[0]
            } else if shareContent {
                streams = [firstStream]
            }

            let contentsEntry = streams.count == 1 ? "\(streams[0]) 0 R" : "[" + streams.map { "\($0) 0 R" }.joined(separator: " ") + "]"
            objects[pageNumber - 1] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " +
                "/Contents \(contentsEntry) /Resources << /Font << /F1 3 0 R /F2 5 0 R /F3 6 0 R >> /Shading << /Sh1 4 0 R >> >> >>"
        }

        objects[1] = "<< /Type /Pages /Kids [" + kids.map { "\($0) 0 R" }.joined(separator: " ") + "] /Count \(kids.count) >>"
        return useObjectStreams ? writeWithStreams(objects) : writeWithTable(objects)
    }

    static func stream(_ data: String) -> String { "<< /Length \(data.utf16.count) >>\nstream\n\(data)\nendstream" }

    /// Writes numbered objects (the first is the catalog) with a cross-reference table.
    static func writeWithTable(_ objects: [String]) -> [UInt8] {
        var pdf = Latin1.bytes("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n")
        var offsets: [Int] = []
        for i in 0..<objects.count {
            offsets.append(pdf.count)
            pdf += Latin1.bytes("\(i + 1) 0 obj\n\(objects[i])\nendobj\n")
        }

        let xref = pdf.count
        pdf += Latin1.bytes("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n")
        for offset in offsets {
            pdf += Latin1.bytes("\(DotNetFormat.d(offset, 10)) 00000 n \n")
        }

        pdf += Latin1.bytes("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        return pdf
    }

    /// Stores every dictionary in one object stream and writes a cross-reference stream (PDF 1.5).
    private static func writeWithStreams(_ objects: [String]) -> [UInt8] {
        let compressed = (1...objects.count).filter { !objects[$0 - 1].ordinalContains("stream") }
        let objectStream = objects.count + 1
        let xrefStream = objects.count + 2
        var header = ""
        var bodies = ""
        for number in compressed {
            header += "\(number) \(bodies.utf16.count) "
            bodies += objects[number - 1] + "\n"
        }

        let packed = deflate(Latin1.bytes(header + bodies))
        var pdf = Latin1.bytes("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n")
        var offsets: [Int: Int] = [:]
        for number in 1...objects.count where !compressed.contains(number) {
            offsets[number] = pdf.count
            pdf += Latin1.bytes("\(number) 0 obj\n\(objects[number - 1])\nendobj\n")
        }

        offsets[objectStream] = pdf.count
        pdf += Latin1.bytes(
            "\(objectStream) 0 obj\n<< /Type /ObjStm /N \(compressed.count) /First \(header.utf16.count) /Filter /FlateDecode /Length \(packed.count) >>\nstream\n")
        pdf += packed
        pdf += Latin1.bytes("\nendstream\nendobj\n")
        offsets[xrefStream] = pdf.count

        // Rows of [type, offset (4 bytes), field 3 (2 bytes)], PNG "Up"-filtered.
        func row(_ type: Int, _ second: Int, _ third: Int) -> [UInt8] {
            [UInt8(type), UInt8(truncatingIfNeeded: second >> 24), UInt8(truncatingIfNeeded: second >> 16), UInt8(truncatingIfNeeded: second >> 8),
             UInt8(truncatingIfNeeded: second), UInt8(truncatingIfNeeded: third >> 8), UInt8(truncatingIfNeeded: third)]
        }

        var rows: [[UInt8]] = []
        for number in 0...xrefStream {
            if number == 0 {
                rows.append(row(0, 0, 65535))
            } else if let index = compressed.firstIndex(of: number) {
                rows.append(row(2, objectStream, index))
            } else {
                rows.append(row(1, offsets[number]!, 0))
            }
        }

        var filtered: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: 7)
        for row in rows {
            filtered.append(2)
            filtered += zip(row, previous).map { $0 &- $1 }
            previous = row
        }

        let data = deflate(filtered)
        pdf += Latin1.bytes(
            "\(xrefStream) 0 obj\n<< /Type /XRef /Size \(xrefStream + 1) /Root 1 0 R /W [1 4 2] /Filter /FlateDecode " +
                "/DecodeParms << /Predictor 12 /Columns 7 >> /Length \(data.count) >>\nstream\n")
        pdf += data
        pdf += Latin1.bytes("\nendstream\nendobj\nstartxref\n\(offsets[xrefStream]!)\n%%EOF\n")
        return pdf
    }

    private static func deflate(_ data: [UInt8]) -> [UInt8] {
        do {
            return try StreamFilters.deflate(data[...])
        } catch {
            preconditionFailure("zlib failed: \(error)")
        }
    }
}
