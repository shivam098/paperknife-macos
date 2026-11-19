import XCTest
@testable import PaperKnifeCore

/// PaperKnife's own reading and writing of PDF syntax, used for content edits.
final class SyntaxTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testLexer_ReadsStringsNamesNumbersAndReferences() throws {
        let lexer = PdfLexer(Latin1.bytes(#"(a\(b\)c\\d\101(e)) <48 65 6C 6C 6F> /A#20B -.5 12 0 R"#))

        XCTAssertEqual(Latin1.string(try XCTUnwrap(lexer.next().bytes)), #"a(b)c\dA(e)"#)
        XCTAssertEqual(Latin1.string(try XCTUnwrap(lexer.next().bytes)), "Hello")
        XCTAssertEqual(lexer.next().text, "A B")
        XCTAssertEqual(lexer.next().number, -0.5)
        let reference = try XCTUnwrap(PdfObjectParser.read(lexer) as? CosRef)
        XCTAssertEqual(reference.number, 12)
    }

    func testPdfFile_ReadsObjectStreamsAndCrossReferenceStreams() throws {
        var problem: String?
        let opened = try PdfFile.tryOpen(RawPdf.build([[RawPdf.baseContent]], useObjectStreams: true), &problem)

        XCTAssertNil(problem)
        let file = try XCTUnwrap(opened)
        XCTAssertTrue(file.hasXrefStream)
        let pages = try XCTUnwrap(file.getPages())
        XCTAssertEqual(pages.count, 1)
        let streams = try XCTUnwrap(file.getContentStreams(pages[0].dict))
        let content = try XCTUnwrap(file.getObject(streams[0].number) as? CosStream)
        XCTAssertEqual(Latin1.string(try XCTUnwrap(file.decodeStream(content))), RawPdf.baseContent)
    }

    func testContentParser_SkipsInlineImageData() throws {
        let ops = try XCTUnwrap(ContentParser.parse(Latin1.bytes(RawPdf.inlineImage + RawPdf.kernedText)))

        XCTAssertEqual(ops.map(\.operator), ["q", "cm", "BI", "Q", "BT", "Tf", "Td", "TJ", "ET"])
    }

    func testContentParser_SkipsInlineImageDataWhoseSizeOverflows() throws {
        // 536870910 gray bytes a row overflow 32 bits; wrapped, the size of 42 rows pointed back at
        // the first EI, so reading went back to it and read the image again, forever.
        let content = Latin1.bytes("EI BI /W 536870910 /H 42 /CS /G /BPC 8 ID x EI")
        let parsed = expectation(description: "The content is parsed.")
        let result = ParsedOperations()
        DispatchQueue.global().async {
            result.ops = ContentParser.parse(content)
            parsed.fulfill()
        }

        wait(for: [parsed], timeout: 10)
        let ops = try XCTUnwrap(result.ops)
        XCTAssertEqual(ops.map(\.operator), ["EI", "BI"])
        XCTAssertEqual(ops[1].end, content.count)
    }

    func testIncrementalUpdate_KeepsEveryOriginalByteAndReplacesTheStream() throws {
        let original = RawPdf.singlePage(RawPdf.baseContent)
        let file = try XCTUnwrap(PdfFile.tryOpen(original))
        let content = try XCTUnwrap(file.getContentStreams(XCTUnwrap(file.getPages())[0].dict))[0]

        let updated = try IncrementalUpdate.append(
            file, [StreamUpdate(content.number, content.generation, Array("BT /F1 24 Tf 72 700 Td (Updated) Tj ET".utf8))])

        XCTAssertTrue(updated.starts(with: original))
        let reread = try XCTUnwrap(PdfFile.tryOpen(updated))
        let stream = try XCTUnwrap(reread.getObject(content.number) as? CosStream)
        XCTAssertEqual(Latin1.string(try XCTUnwrap(reread.decodeStream(stream))), "BT /F1 24 Tf 72 700 Td (Updated) Tj ET")

        // The C# test reads the runs of a DocumentSession; until that is ported, PDFium's own text
        // of the page shows that PDFium reads the update too.
        let text = try XCTUnwrap(SyntaxTestSupport.pdfiumText(updated, page: 0))
        XCTAssertTrue(text.ordinalContains("Updated"), text)
    }

    func testStreamFilters_RefuseDataThatExpandsTooFar() throws {
        // Each two-byte RunLength run expands to 128 bytes; Flate shrinks the runs to almost nothing.
        var runs = [UInt8](repeating: 0, count: 2 * (StreamFilters.maxDecodedLength / 128 + 1))
        var i = 0
        while i < runs.count {
            runs[i] = 129
            runs[i + 1] = UInt8(ascii: "A")
            i += 2
        }

        var problem: String?
        let decoded = try StreamFilters.decode(StreamFilters.deflate(runs[...])[...], ["FlateDecode", "RunLengthDecode"], [], &problem)

        XCTAssertNil(decoded)
        XCTAssertNotNil(problem)
    }

    func testStreamFilters_TreatFlateDataThatNeedsAPresetDictionaryAsDamaged() throws {
        // A zlib header asking for a preset dictionary (FDICT), which a PDF can't give, then a
        // stored block: .NET's ZLibStream throws ZLibException for it, not InvalidDataException.
        let data: [UInt8] = [0x78, 0xBB, 0, 0, 0, 1, 0x01, 0x01, 0x00, 0xFE, 0xFF, UInt8(ascii: "A")]

        var problem: String?
        XCTAssertNil(try StreamFilters.decode(data[...], ["FlateDecode"], [], &problem))
        XCTAssertNotNil(problem)
        XCTAssertNil(try StreamFilters.inflatePrefix(data[...], 1))
    }

    func testFontInfo_GivesUpQuicklyOnWidthMapsTooLargeToRead() throws {
        let file = try XCTUnwrap(PdfFile.tryOpen(RawPdf.singlePage(RawPdf.baseContent)))
        var widths: [CosObject] = []
        for _ in 0..<100_000 {
            widths += [number(0), number(131_000), number(500)]
        }

        var descendant = OrderedDictionary<String, CosObject>()
        descendant["W"] = CosArray(widths)
        var entries = OrderedDictionary<String, CosObject>()
        entries["Subtype"] = CosName("Type0")
        entries["Encoding"] = CosName("Identity-H")
        entries["DescendantFonts"] = CosArray([CosDict(descendant)])
        let font = CosDict(entries)
        let start = Date()

        let info = try PdfFontInfo.load(file, font)

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertNil(info.width(65))
    }

    func testPdfFile_RefusesObjectStreamsInsideObjectStreams() throws {
        // Object n lives in object stream n + 1, 100 000 levels deep: following the chain would
        // overflow the stack. Like PDFium, PaperKnife only reads object streams that are ordinary objects.
        let count = 100_000
        var rows: [UInt8] = [0, 0, 0, 0, 0]
        for n in 1...count {
            rows += [2, UInt8(truncatingIfNeeded: (n + 1) >> 16), UInt8(truncatingIfNeeded: (n + 1) >> 8), UInt8(truncatingIfNeeded: n + 1), 0]
        }

        let header = "%PDF-1.7\n"
        let xrefNumber = count + 2
        rows += [1, 0, UInt8(header.utf8.count >> 8), UInt8(header.utf8.count & 0xFF), 0]
        let data = try StreamFilters.deflate(rows[...])
        let pdf = Latin1.bytes(header +
            "\(xrefNumber) 0 obj\n<< /Type /XRef /Size \(xrefNumber + 1) /Index [0 \(count + 1) \(xrefNumber) 1] /W [1 3 1] /Root 1 0 R /Filter /FlateDecode /Length \(data.count) >>\nstream\n")
            + data
            + Latin1.bytes("\nendstream\nendobj\nstartxref\n\(header.utf8.count)\n%%EOF\n")

        var problem: String?
        let file = try PdfFile.tryOpen(pdf, &problem)

        XCTAssertNil(problem)
        XCTAssertNil(try XCTUnwrap(file).getPages())
    }

    private func number(_ value: Int) -> CosNumber { CosNumber(Double(value), String(value)) }
}

/// What a parse on another thread gave, for a test that mustn't hang if the parser loops.
private final class ParsedOperations: @unchecked Sendable {
    var ops: [ContentOp]?
}
