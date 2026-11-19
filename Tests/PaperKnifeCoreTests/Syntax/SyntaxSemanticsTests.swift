import XCTest
@testable import PaperKnifeCore

/// The .NET behaviour the Syntax, Content and Fonts layers reproduce in Swift: number parsing, text
/// decoding, glyph names, zlib's handling of damaged data, and the exceptions C# throws while reading.
final class SyntaxSemanticsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testNumbersParseAsDotNetParsesThem() {
        // double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, ...)
        let cases: [(String, Double?)] = [
            ("1.5", 1.5), ("-.5", -0.5), ("5.", 5), ("+7", 7), ("1e3", 1000), ("2.5E-1", 0.25), (" 2 ", 2),
            ("1.5\u{0}", 1.5), ("1e", nil), ("0x10", nil), ("- 5", nil), (".", nil), ("", nil), ("1,5", nil), ("1.2.3", nil),
            ("Infinity", .infinity), ("-infinity", -.infinity),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(DotNetParse.double(text.utf16), expected, text)
        }

        XCTAssertEqual(DotNetParse.double("-0".utf16)?.sign, .minus)
        XCTAssertTrue(DotNetParse.double("NaN".utf16)?.isNaN == true)

        // int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, ...)
        XCTAssertEqual(DotNetParse.signedInt32("-1".utf16), -1)
        XCTAssertEqual(DotNetParse.signedInt32("+32".utf16), 32)
        XCTAssertEqual(DotNetParse.signedInt32("-2147483648".utf16), Int(Int32.min))
        XCTAssertNil(DotNetParse.signedInt32("2147483648".utf16))
        XCTAssertNil(DotNetParse.signedInt32(" 5".utf16))
        XCTAssertNil(DotNetParse.signedInt32("5 ".utf16))

        // int.TryParse(text, NumberStyles.AllowHexSpecifier, ...) ignores trailing NULs.
        XCTAssertEqual(DotNetParse.hexInt32("41\u{0}\u{0}".utf16), 0x41)
        XCTAssertNil(DotNetParse.hexInt32("\u{0}".utf16))
        XCTAssertNil(DotNetParse.hexInt32("4\u{0}1".utf16))

        // The lexer's numbers keep their spelling.
        let lexer = PdfLexer(Latin1.bytes("-0 +.5 12. 3.4.5"))
        XCTAssertEqual(lexer.next().number.sign, .minus)
        XCTAssertEqual(lexer.next().number, 0.5)
        XCTAssertEqual(lexer.next().number, 12)
        XCTAssertEqual(lexer.next().kind, .keyword)
    }

    func testTextDecodesAsDotNetDecodesIt() {
        // Encoding.BigEndianUnicode.GetString replaces unpaired surrogates and an odd last byte.
        XCTAssertEqual(Utf16BigEndian.string([0x00, 0x41, 0x00, 0x42]), "AB")
        XCTAssertEqual(Utf16BigEndian.string([0x00, 0x41, 0x42]), "A\u{FFFD}")
        XCTAssertEqual(Utf16BigEndian.string([0xD8, 0x3D, 0xDE, 0x00]), "\u{1F600}")
        XCTAssertEqual(Utf16BigEndian.string([0xD8, 0x3D, 0x00, 0x41]), "\u{FFFD}A")
        XCTAssertEqual(DotNetFormat.d(42, 10), "0000000042")
        XCTAssertEqual(DotNetFormat.d(-5, 3), "-005")
        XCTAssertEqual(DotNetFormat.hex([0x00, 0xAB, 0xFF]), "00ABFF")
    }

    func testGlyphNamesStandForTheirText() {
        XCTAssertEqual(Encodings.winAnsiName(32), "space")
        XCTAssertNil(Encodings.winAnsiName(127))
        XCTAssertEqual(Encodings.winAnsiName(128), "Euro")
        XCTAssertNil(Encodings.winAnsiName(129))
        XCTAssertEqual(Encodings.winAnsiName(255), "ydieresis")
        XCTAssertEqual(Encodings.standardName(39), "quoteright")
        XCTAssertEqual(Encodings.fullStandardName(0xAE), "fi")
        XCTAssertNil(Encodings.macRomanName(200))

        XCTAssertEqual(Encodings.glyphToUnicode("Euro"), "\u{20AC}")
        XCTAssertEqual(Encodings.glyphToUnicode("quoteright"), "\u{2019}")
        XCTAssertEqual(Encodings.glyphToUnicode("f_f_i"), "ffi")
        XCTAssertNil(Encodings.glyphToUnicode("f__i"))
        XCTAssertEqual(Encodings.glyphToUnicode("a.sc"), "a")
        XCTAssertNil(Encodings.glyphToUnicode(".notdef"))
        XCTAssertEqual(Encodings.glyphToUnicode("uni0041"), "A")
        XCTAssertEqual(Encodings.glyphToUnicode("u1F600"), "\u{1F600}")
        XCTAssertNil(Encodings.glyphToUnicode("uD800"))

        // From the Adobe Glyph List, which the app reads from its bundle.
        XCTAssertEqual(Encodings.glyphToUnicode("dalethatafpatah"), "\u{05D3}\u{05B2}")
        XCTAssertEqual(Encodings.glyphToUnicode("Zcaron"), "\u{017D}")
        XCTAssertEqual(Encodings.expandLigatures("\u{FB01}x\u{FB05}"), "fix\u{017F}t")
    }

    func testCosWriterWritesNamesAndDictionariesInOrder() throws {
        var name = ""
        CosWriter.writeName(&name, "A B#(\u{E9}")
        XCTAssertEqual(name, "/A#20B#23#28#E9")

        var entries = OrderedDictionary<String, CosObject>()
        entries["Type"] = CosName("Font")
        entries["Size"] = CosNumber(3, "3")
        entries["Kids"] = CosArray([CosRef(4, 0), CosString([0x48, 0x69]), CosBool(true), CosNull.instance])
        XCTAssertEqual(try CosWriter.toText(CosDict(entries)), "<</Type /Font/Size 3/Kids [4 0 R <4869> true null]>>")
        XCTAssertThrowsError(try CosWriter.toText(CosStream(CosDict(OrderedDictionary()), 0, 0))) { error in
            XCTAssertEqual((error as? ArgumentException)?.message, "Streams can't be written inline. (Parameter 'value')")
        }

        XCTAssertEqual(CosWriter.number(-0.00000000001), "0")
        XCTAssertEqual(CosWriter.number(1.0 / 3), "0.3333333333")
    }

    func testFlateDataIsReadAsDotNetReadsIt() throws {
        let text = Array(String(repeating: "Hello, World. ", count: 200).utf8)
        let compressed = try StreamFilters.deflate(text[...])
        var problem: String?

        // Bytes after the end are ignored, and truncated data gives what it holds.
        XCTAssertEqual(try StreamFilters.decode((compressed + [1, 2, 3])[...], ["FlateDecode"], [], &problem), text)
        let truncated = try XCTUnwrap(StreamFilters.decode(compressed[0..<(compressed.count / 2)], ["Fl"], [], &problem))
        XCTAssertTrue(text.starts(with: truncated))
        XCTAssertEqual(try StreamFilters.decode([][...], ["FlateDecode"], [], &problem), [])

        // Damaged data (a reserved block type) can't be decoded.
        XCTAssertNil(try StreamFilters.decode([0x78, 0x9C, 0xFF, 0xFF][...], ["FlateDecode"], [], &problem))
        XCTAssertEqual(problem, "The stream's FlateDecode data can't be decoded.")

        // A stream that needs a preset dictionary makes zlib return Z_NEED_DICT, for which .NET
        // throws a ZLibException rather than report damaged data.
        XCTAssertThrowsError(try StreamFilters.decode([0x78, 0x20, 0, 0, 0, 1][...], ["FlateDecode"], [], &problem)) { error in
            XCTAssertTrue(error is ZLibException, "\(error)")
        }

        XCTAssertEqual(try StreamFilters.inflatePrefix(compressed[...], 5), Array("Hello".utf8))
    }

    func testReadingThrowsWhereCSharpThrows() throws {
        // An inline image's size is computed in 32 bits; when it wraps, C# reads at a negative offset.
        XCTAssertThrowsError(try ContentParser.parse(Latin1.bytes("BI /W 10000000000 /H 1 /CS /G /BPC 1 ID x EI"))) { error in
            XCTAssertTrue(error is IndexOutOfRangeException, "\(error)")
        }

        // C#'s List indexer throws ArgumentOutOfRangeException.
        XCTAssertThrowsError(try CosArray([CosNull.instance])[1]) { error in
            XCTAssertTrue(error is ArgumentOutOfRangeException, "\(error)")
        }

        // Enumerable.Max of no updates throws InvalidOperationException.
        let file = try XCTUnwrap(PdfFile.tryOpen(RawPdf.singlePage(RawPdf.baseContent)))
        XCTAssertThrowsError(try IncrementalUpdate.append(file, [])) { error in
            XCTAssertTrue(error is InvalidOperationException, "\(error)")
        }
    }

    func testIncrementalUpdateOfAFileWithACrossReferenceStream() throws {
        let original = RawPdf.build([[RawPdf.baseContent]], useObjectStreams: true)
        let file = try XCTUnwrap(PdfFile.tryOpen(original))
        let content = try XCTUnwrap(file.getContentStreams(XCTUnwrap(file.getPages())[0].dict))[0]

        let updated = try IncrementalUpdate.append(file, [StreamUpdate(content.number, content.generation, Array("BT ET".utf8))])

        XCTAssertTrue(updated.starts(with: original))
        let reread = try XCTUnwrap(PdfFile.tryOpen(updated))
        XCTAssertTrue(reread.hasXrefStream)
        XCTAssertGreaterThan(reread.startXref, original.count)
        XCTAssertEqual(reread.size, file.size + 1)
        XCTAssertEqual((reread.trailer["Prev"] as? CosNumber)?.value, Double(file.startXref))
        let stream = try XCTUnwrap(reread.getObject(content.number) as? CosStream)
        XCTAssertEqual(try reread.decodeStream(stream), Array("BT ET".utf8))
        XCTAssertEqual(try reread.getPages()?.count, 1)
    }
}
