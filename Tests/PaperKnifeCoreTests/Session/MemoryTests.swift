import Darwin
import XCTest
@testable import PaperKnifeCore

/// What PaperKnife keeps in memory while pages are viewed (MemoryTests.cs). XCTest runs tests one
/// at a time, so the memory they measure is theirs alone.
final class MemoryTests: XCTestCase {
    private static let megabyte = 1024 * 1024

    // The most codes one bfrange of a character map may cover for PaperKnife to read it.
    private static let rangeSize = 1 << 17

    func testViewingPages_WhoseFontsShareACharacterMap_KeepsOneCopyOfIt() throws {
        // Every page has a font of its own, and all of them share one map of 262,144 codes, which
        // takes about 15 MB once read. Fonts used to keep a copy each: as much again per page viewed.
        let retained = try Self.retainedAfterViewing(Self.pages(48, sharedMap: true, codes: 2 * Self.rangeSize))

        XCTAssertLessThan(retained, 48 * Self.megabyte, "\(retained / Self.megabyte) MB stayed in memory.")
    }

    func testViewingManyPages_WithLargeCharacterMaps_KeepsOnlyRecentPagesFonts() throws {
        // Every page's font has a map of its own, of 32,768 codes: about 2 MB once read. Only the
        // fonts of the last pages viewed need to stay.
        let retained = try Self.retainedAfterViewing(Self.pages(160, sharedMap: false, codes: Self.rangeSize / 4))

        XCTAssertLessThan(retained, 96 * Self.megabyte, "\(retained / Self.megabyte) MB stayed in memory.")
    }

    /// The memory that stays in use after every page is viewed, while the document is still open.
    private static func retainedAfterViewing(_ pdf: [UInt8]) throws -> Int {
        let session = try DocumentSession.fromSnapshot(PdfSnapshot.fromBytes(pdf))
        defer {
            session.dispose()
        }

        let before = memoryInUse()
        let pageCount = try session.pageCount
        for page in 0..<pageCount {
            _ = try session.getTextEditBlockers(page)
        }

        let retained = memoryInUse() - before
        withExtendedLifetime(session) {}
        return retained
    }

    /// The bytes allocated and not yet freed, in every malloc zone. C# collects garbage first;
    /// Swift frees memory as soon as nothing refers to it.
    private static func memoryInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// Pages that each draw a word in a Helvetica font of their own, whose ToUnicode map covers
    /// `codes` codes: one map for all of them, or one map each.
    private static func pages(_ count: Int, sharedMap: Bool, codes: Int) -> [UInt8] {
        let map = RawPdf.stream(characterMap(codes))
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        if sharedMap {
            objects.append(map)
        }

        var kids: [Int] = []
        for _ in 0..<count {
            let page = objects.count + 1
            kids.append(page)
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(page + 1) 0 R /Resources << /Font << /F1 \(page + 2) 0 R >> >> >>")
            objects.append(RawPdf.stream("BT /F1 24 Tf 72 700 Td (Hello) Tj ET"))
            objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode \(sharedMap ? 3 : page + 3) 0 R >>")
            if !sharedMap {
                objects.append(map)
            }
        }

        objects[1] = "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(count) >>"
        return RawPdf.writeWithTable(objects)
    }

    /// A ToUnicode CMap whose bfranges map `codes` codes, each to a text of its own.
    private static func characterMap(_ codes: Int) -> String {
        let ranges = (codes + rangeSize - 1) / rangeSize
        var map = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Large def /CMapType 2 def\n"
        map += "\(ranges) beginbfrange\n"
        for start in stride(from: 0, to: codes, by: rangeSize) {
            map += "<\(String(format: "%06X", start))> <\(String(format: "%06X", min(codes, start + rangeSize) - 1))> <4E00>\n"
        }

        return map + "endbfrange\nendcmap CMapName currentdict /CMap defineresource pop end end"
    }
}
