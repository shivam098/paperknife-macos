/// A page's decoded content and the text-showing operations in it, ready for content edits.
final class ContentPage {
    let file: PdfFile

    let page: PdfPageNode

    /// The page's content streams; an edit writes the whole content into the first.
    let streams: [CosRef]

    /// The decoded content streams, joined by spaces as PDFium joins them.
    let content: [UInt8]

    let ops: [ContentOp]

    /// The text layout using only widths from font dictionaries.
    let text: ContentTextLayout

    init(file: PdfFile, page: PdfPageNode, streams: [CosRef], content: [UInt8], ops: [ContentOp], text: ContentTextLayout) {
        self.file = file
        self.page = page
        self.streams = streams
        self.content = content
        self.ops = ops
        self.text = text
    }

    /// The page's content, or nil when PaperKnife can't read it with certainty.
    static func tryLoad(_ file: PdfFile, _ pages: [PdfPageNode], _ pageIndex: Int) throws -> ContentPage? {
        guard pageIndex >= 0 && pageIndex < pages.count else {
            throw DotNetThrows.listIndexOutOfRange()
        }

        let page = pages[pageIndex]
        guard let streams = try file.getContentStreams(page.dict), streams.map(\.number).distinctInOrder().count == streams.count else {
            return nil
        }

        // Writing a new version of a stream that another page also draws would change that page too.
        let own = Set(streams.map(\.number))
        for i in 0..<pages.count where i != pageIndex {
            if try contentNumbers(file, pages[i].dict).contains(where: own.contains) {
                return nil
            }
        }

        // PDFium joins a page's content streams with one space; anything else would let a
        // comment at the end of one stream end differently than PDFium reads it.
        var content: [UInt8] = []
        for reference in streams {
            guard let stream = try file.getObject(reference.number) as? CosStream, let data = try file.decodeStream(stream),
                content.count + data.count <= StreamFilters.maxDecodedLength else {
                return nil
            }

            content += data
            content.append(UInt8(ascii: " "))
        }

        guard let ops = ContentParser.parse(content) else {
            return nil
        }

        return ContentPage(
            file: file, page: page, streams: streams, content: content, ops: ops, text: try TextShowSimulator.run(ops, file, page.resources))
    }

    private static func contentNumbers(_ file: PdfFile, _ page: CosDict) throws -> [Int] {
        var contents = page["Contents"]
        if let reference = contents as? CosRef, let indirect = try file.getObject(reference.number) as? CosArray {
            contents = indirect
        }

        if let reference = contents as? CosRef {
            return [reference.number]
        }

        if let array = contents as? CosArray {
            return array.items.compactMap { ($0 as? CosRef)?.number }
        }

        return []
    }
}
