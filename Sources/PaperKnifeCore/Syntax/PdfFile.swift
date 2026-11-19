/// Where an object lives: free (type 0), at an offset (1), or inside an object stream (2).
struct XrefEntry {
    let type: Int

    let offset: Int

    let generation: Int

    let streamNumber: Int

    let index: Int

    init(_ type: Int, _ offset: Int, _ generation: Int, _ streamNumber: Int, _ index: Int) {
        self.type = type
        self.offset = offset
        self.generation = generation
        self.streamNumber = streamNumber
        self.index = index
    }
}

/// A page of the page tree, with the resources it inherits.
struct PdfPageNode {
    let number: Int

    let generation: Int

    let dict: CosDict

    let resources: CosDict?

    init(_ number: Int, _ generation: Int, _ dict: CosDict, _ resources: CosDict?) {
        self.number = number
        self.generation = generation
        self.dict = dict
        self.resources = resources
    }
}

/// A read-only view of a PDF file's structure (ISO 32000-1, 7.5): cross-reference tables and
/// streams, the trailer, indirect objects, object streams and the page tree. It reads only what it
/// is asked for, and returns nil for anything it doesn't fully understand instead of guessing the
/// way PDFium's recovery does; callers then leave the file to PDFium.
///
/// Methods throw where the C# reader throws: zlib's `ZLibException`, and the exceptions
/// DocumentSession treats as read failures.
final class PdfFile {
    /// The highest object number PDFium accepts (cpdf_parser.h, kMaxObjectNumber).
    static let maxObjectNumber = 24 * 1024 * 1024

    private static let maxSections = 1000
    private static let maxNesting = 32

    private var xref: [Int: XrefEntry] = [:]
    private var objects: [Int: CosObject?] = [:]
    private var objectStreams: [Int: ObjectStream?] = [:]
    private var derivedValues: [DerivedKey: Any?] = [:]
    private var loading = Set<Int>()

    private init(_ data: [UInt8]) {
        self.data = data
    }

    let data: [UInt8]

    /// The newest trailer dictionary (for a cross-reference stream, its dictionary).
    private(set) var trailer = CosDict(OrderedDictionary())

    /// The offset of the newest cross-reference section, which an update's /Prev names.
    private(set) var startXref = 0

    /// Whether the newest cross-reference section is a stream rather than a table.
    private(set) var hasXrefStream = false

    /// One more than the highest object number in use.
    private(set) var size = 0

    var isEncrypted: Bool { trailer["Encrypt"] != nil }

    static func tryOpen(_ data: [UInt8], _ problem: inout String?) throws -> PdfFile? {
        let file = PdfFile(data)
        problem = try file.readCrossReferences()
        return problem == nil ? file : nil
    }

    /// `tryOpen` without the problem.
    static func tryOpen(_ data: [UInt8]) throws -> PdfFile? {
        var problem: String?
        return try tryOpen(data, &problem)
    }

    func getObject(_ number: Int) throws -> CosObject? {
        if let cached = objects[number] {
            return cached
        }

        // A chain of references (a stream length, an object stream) mustn't recurse without limit.
        if loading.count > Self.maxNesting || !loading.insert(number).inserted {
            return nil
        }

        defer {
            loading.remove(number)
        }

        var value: CosObject?
        if let entry = xref[number] {
            switch entry.type {
            case 1:
                if let read = try readObjectAt(entry.offset), read.number == number {
                    value = read.value
                }
            case 2:
                value = try readFromObjectStream(entry.streamNumber, entry.index, number)
            default:
                break
            }
        }

        objects.updateValue(value, forKey: number)
        return value
    }

    /// Follows references; nil for null objects, missing objects and reference loops.
    func resolve(_ value: CosObject?) throws -> CosObject? {
        var value = value
        var depth = 0
        while let reference = value as? CosRef, depth < 32 {
            value = try getObject(reference.number)
            depth += 1
        }

        return value is CosNull || value is CosRef ? nil : value
    }

    func resolveDict(_ value: CosObject?) throws -> CosDict? { try resolve(value) as? CosDict }

    func resolveArray(_ value: CosObject?) throws -> CosArray? { try resolve(value) as? CosArray }

    func resolveNumber(_ value: CosObject?) throws -> Double? { (try resolve(value) as? CosNumber)?.value }

    func resolveName(_ value: CosObject?) throws -> String? { (try resolve(value) as? CosName)?.value }

    /// A value derived from an indirect object, such as a font's character map, computed once
    /// however many resource names, fonts or pages refer to the object, until `forgetDerived`. A
    /// reader kept open while pages are viewed calls that to bound what it keeps.
    func derived<T>(_ kind: String, _ number: Int, _ compute: () throws -> T?) rethrows -> T? {
        let key = DerivedKey(kind: kind, number: number)
        if let cached = derivedValues[key] {
            return cached as? T
        }

        let value = try compute()
        derivedValues.updateValue(value.map { $0 as Any }, forKey: key)
        return value
    }

    /// Forgets the values `derived` computed; they are computed again when needed.
    func forgetDerived() {
        derivedValues.removeAll()
    }

    /// The first `length` bytes of the stream's decoded data, or nil when it is shorter or can't be
    /// decoded. Flate data is decoded only that far.
    func decodeStreamPrefix(_ stream: CosStream, _ length: Int, _ limit: Int) throws -> [UInt8]? {
        let filter = try resolve(stream.dict["Filter"])
        if stream.dict["F"] == nil && stream.dict["DecodeParms"] == nil
            && (filter == nil || ((filter as? CosName).map { $0.value == "FlateDecode" || $0.value == "Fl" } ?? false)) {
            let raw = data[stream.dataStart..<(stream.dataStart + stream.dataLength)]
            let prefix: [UInt8]?
            if filter == nil {
                guard length >= 0 else {
                    throw DotNetThrows.spanOutOfRange()
                }

                prefix = Array(raw.prefix(length))
            } else {
                prefix = try StreamFilters.inflatePrefix(raw, length)
            }

            if let p = prefix, p.count == length {
                return p
            }

            return nil
        }

        var problem: String?
        if let data = try decodeStream(stream, &problem, limit: limit), data.count >= length {
            return Array(data[0..<length])
        }

        return nil
    }

    /// The stream's decoded data, or nil when it can't be decoded or would be longer than `limit` bytes.
    func decodeStream(_ stream: CosStream, _ problem: inout String?, limit: Int = StreamFilters.maxDecodedLength) throws -> [UInt8]? {
        var filters: [String] = []
        var parameters: [CosDict?] = []
        let filter = try resolve(stream.dict["Filter"])
        let decodeParameters = try resolve(stream.dict["DecodeParms"])
        if stream.dict["F"] != nil {
            problem = "The stream's data is in an external file."
            return nil
        }

        if let name = filter as? CosName {
            filters.append(name.value)
            parameters.append(decodeParameters as? CosDict)
        } else if let array = filter as? CosArray {
            for i in 0..<array.count {
                guard let name = try resolve(array.items[i]) as? CosName else {
                    problem = "The stream has an unknown filter."
                    return nil
                }

                filters.append(name.value)
                if let all = decodeParameters as? CosArray, i < all.count {
                    parameters.append(try resolveDict(all.items[i]))
                } else {
                    parameters.append(nil)
                }
            }
        } else if filter != nil {
            problem = "The stream has an unknown filter."
            return nil
        }

        return try StreamFilters.decode(
            data[stream.dataStart..<(stream.dataStart + stream.dataLength)], filters, parameters, &problem, limit: limit)
    }

    /// `decodeStream` without the problem.
    func decodeStream(_ stream: CosStream, limit: Int = StreamFilters.maxDecodedLength) throws -> [UInt8]? {
        var problem: String?
        return try decodeStream(stream, &problem, limit: limit)
    }

    /// The pages in document order, or nil when the page tree isn't sound.
    func getPages() throws -> [PdfPageNode]? {
        guard let catalog = try resolveDict(trailer["Root"]), let root = catalog["Pages"] as? CosRef else {
            return nil
        }

        var pages: [PdfPageNode] = []
        var visited = Set<Int>()
        return try collectPages(root, nil, &pages, &visited, 0) ? pages : nil
    }

    /// The page's content streams, in order, or nil when /Contents isn't a stream or an array of streams.
    func getContentStreams(_ page: CosDict) throws -> [CosRef]? {
        var contents = page["Contents"]
        if contents == nil {
            return []
        }

        if let reference = contents as? CosRef {
            let object = try getObject(reference.number)
            if object is CosStream {
                return [reference]
            }

            guard let array = object as? CosArray else {
                return nil
            }

            contents = array
        }

        guard let items = contents as? CosArray else {
            return nil
        }

        var streams: [CosRef] = []
        for item in items.items {
            guard let r = item as? CosRef, try getObject(r.number) is CosStream else {
                return nil
            }

            streams.append(r)
        }

        return streams
    }

    private func collectPages(_ node: CosRef, _ inherited: CosDict?, _ pages: inout [PdfPageNode], _ visited: inout Set<Int>, _ depth: Int) throws -> Bool {
        if depth > 64 || !visited.insert(node.number).inserted {
            return false
        }

        guard let dict = try getObject(node.number) as? CosDict else {
            return false
        }

        let resources = try dict["Resources"] != nil ? resolveDict(dict["Resources"]) : inherited
        let kids = try resolveArray(dict["Kids"])
        let type = try resolveName(dict["Type"])
        if type == "Pages" || (type != "Page" && kids != nil) {
            guard let kids else {
                return false
            }

            for kid in kids.items {
                guard let r = kid as? CosRef, try collectPages(r, resources, &pages, &visited, depth + 1) else {
                    return false
                }
            }

            return true
        }

        pages.append(PdfPageNode(node.number, node.generation, dict, resources))
        return true
    }

    private func readCrossReferences() throws -> String? {
        let tail = max(0, data.count - 4096)
        guard let at = Self.lastIndex(of: Array("startxref".utf8), in: data, from: tail) else {
            return "The file has no cross-reference offset."
        }

        let offset = PdfLexer(data, at + 9).next()
        if offset.kind != .number || offset.number < 0 {
            return "The file's cross-reference offset is damaged."
        }

        startXref = DotNetMath.toInt64(offset.number)
        var pending = [startXref]
        var head = 0
        var visited = Set<Int>()
        var newest = true
        while head < pending.count {
            let position = pending[head]
            head += 1
            if position < 0 || position >= data.count || !visited.insert(position).inserted || visited.count > Self.maxSections {
                return "The file's cross-reference sections are damaged."
            }

            let isStream = !PdfLexer(data, position).peek().isKeyword("xref")
            var trailer: CosDict?
            let problem: String?
            if isStream {
                problem = try readXrefStream(position, &trailer)
            } else {
                problem = readXrefTable(position, &trailer)
            }

            if let problem {
                return problem
            }

            if newest {
                self.trailer = trailer!
                hasXrefStream = isStream
                newest = false
            }

            if !isStream, let hybrid = trailer!["XRefStm"] as? CosNumber {
                var ignored: CosDict?
                if let problem = try readXrefStream(DotNetMath.toInt64(hybrid.value), &ignored) {
                    return problem
                }
            }

            if let prev = trailer!["Prev"] as? CosNumber {
                pending.append(DotNetMath.toInt64(prev.value))
            }
        }

        var size = 0
        if let s = self.trailer["Size"] as? CosNumber, s.isInteger, s.value >= 0 && s.value <= Double(Int32.max) {
            size = DotNetMath.toInt64(s.value)
        }

        self.size = min(Int(Int32.max), max(size, xref.isEmpty ? 1 : xref.keys.max()! + 1))
        return self.trailer["Root"] is CosRef ? nil : "The file has no catalog."
    }

    private func readXrefTable(_ position: Int, _ trailer: inout CosDict?) -> String? {
        trailer = nil
        let lexer = PdfLexer(data, position)
        _ = lexer.next()
        while true {
            let first = lexer.next()
            if first.isKeyword("trailer") {
                break
            }

            let count = lexer.next()
            if !Self.isCount(first) || !Self.isCount(count) {
                return "The file's cross-reference table is damaged."
            }

            var i = 0
            while i < DotNetMath.toInt32(count.number) {
                let offset = lexer.next()
                let generation = lexer.next()
                let kind = lexer.next()
                if !Self.isCount(offset) || !Self.isCount(generation) || kind.kind != .keyword || (kind.text != "n" && kind.text != "f") {
                    return "The file's cross-reference table is damaged."
                }

                // C# adds in 32 bits: a subsection near the largest number wraps around.
                let number = Int(Int32(DotNetMath.toInt32(first.number)) &+ Int32(i))
                if xref[number] == nil {
                    xref[number] = kind.text == "n"
                        ? XrefEntry(1, DotNetMath.toInt64(offset.number), DotNetMath.toInt32(generation.number), 0, 0)
                        : XrefEntry(0, 0, DotNetMath.toInt32(generation.number), 0, 0)
                }

                i += 1
            }
        }

        trailer = PdfObjectParser.read(lexer) as? CosDict
        return trailer == nil ? "The file's trailer is damaged." : nil
    }

    private func readXrefStream(_ position: Int, _ trailer: inout CosDict?) throws -> String? {
        trailer = nil
        guard position >= 0, position < data.count, let stream = try readObjectAt(position)?.value as? CosStream,
            try resolveName(stream.dict["Type"]) == "XRef" else {
            return "The file's cross-reference stream is damaged."
        }

        var problem: String?
        guard let data = try decodeStream(stream, &problem) else {
            return problem
        }

        guard let w = stream.dict["W"] as? CosArray, w.count == 3,
            w.items.allSatisfy({ ($0 as? CosNumber).map { $0.value >= 0 && $0.value <= 8 } ?? false }) else {
            return "The file's cross-reference stream is damaged."
        }

        let widths = w.items.map { DotNetMath.toInt32(($0 as! CosNumber).value) }
        let size = (stream.dict["Size"] as? CosNumber).map { DotNetMath.toInt32($0.value) } ?? 0
        let index = (stream.dict["Index"] as? CosArray).map { array in
            array.items.map { ($0 as? CosNumber).map { DotNetMath.toInt32($0.value) } ?? -1 }
        } ?? [0, size]
        let entrySize = widths.reduce(0, +)
        if entrySize == 0 {
            return "The file's cross-reference stream is damaged."
        }

        var at = 0
        var pair = 0
        while pair + 1 < index.count {
            if index[pair] < 0 || index[pair + 1] < 0 {
                return "The file's cross-reference stream is damaged."
            }

            for n in 0..<index[pair + 1] {
                if at + entrySize > data.count {
                    return "The file's cross-reference stream is damaged."
                }

                let type = widths[0] == 0 ? 1 : Self.field(data, at, widths[0])
                let second = Self.field(data, at + widths[0], widths[1])
                let third = Self.field(data, at + widths[0] + widths[1], widths[2])
                at += entrySize

                // C# adds in 32 bits and narrows longs to ints by dropping their high bits.
                let number = Int(Int32(index[pair]) &+ Int32(n))
                let entry: XrefEntry?
                switch type {
                case 0: entry = XrefEntry(0, 0, Int(Int32(truncatingIfNeeded: third)), 0, 0)
                case 1: entry = XrefEntry(1, second, Int(Int32(truncatingIfNeeded: third)), 0, 0)
                case 2: entry = XrefEntry(2, 0, 0, Int(Int32(truncatingIfNeeded: second)), Int(Int32(truncatingIfNeeded: third)))
                default: entry = nil
                }

                if let entry, xref[number] == nil {
                    xref[number] = entry
                }
            }

            pair += 2
        }

        trailer = stream.dict
        return nil
    }

    private static func field(_ data: [UInt8], _ start: Int, _ width: Int) -> Int {
        var value = 0
        for i in 0..<width {
            value = (value << 8) | Int(data[start + i])
        }

        return value
    }

    private static func isCount(_ token: PdfToken) -> Bool {
        token.kind == .number && token.number >= 0 && !token.text.utf16.contains(0x2E)
    }

    /// Reads "n g obj ... endobj" at an offset; nil when it isn't one or a stream's length is wrong.
    private func readObjectAt(_ position: Int) throws -> (number: Int, generation: Int, value: CosObject)? {
        if position < 0 || position >= data.count {
            return nil
        }

        let lexer = PdfLexer(data, position)
        let number = lexer.next()
        let generation = lexer.next()
        guard Self.isCount(number), Self.isCount(generation), lexer.next().isKeyword("obj"), var value = PdfObjectParser.read(lexer) else {
            return nil
        }

        if let dict = value as? CosDict, lexer.peek().isKeyword("stream") {
            var start = lexer.next().end
            if start < data.count && data[start] == 13 {
                start += 1
            }

            if start < data.count && data[start] == 10 {
                start += 1
            }

            guard let length = try resolveNumber(dict["Length"]), length >= 0, Double(start) + length <= Double(data.count),
                PdfLexer(data, start + DotNetMath.toInt32(length)).next().isKeyword("endstream") else {
                return nil
            }

            value = CosStream(dict, start, DotNetMath.toInt32(length))
        }

        return (DotNetMath.toInt32(number.number), DotNetMath.toInt32(generation.number), value)
    }

    private func readFromObjectStream(_ streamNumber: Int, _ index: Int, _ number: Int) throws -> CosObject? {
        let parsed: ObjectStream?
        if let cached = objectStreams[streamNumber] {
            parsed = cached
        } else {
            parsed = try parseObjectStream(streamNumber)
            objectStreams.updateValue(parsed, forKey: streamNumber)
        }

        guard let objects = parsed else {
            return nil
        }

        let i = index >= 0 && index < objects.numbers.count && objects.numbers[index] == number
            ? index
            : objects.numbers.firstIndex(of: number) ?? -1
        return i < 0 ? nil : PdfObjectParser.read(PdfLexer(objects.data, objects.first + objects.offsets[i]))
    }

    private func parseObjectStream(_ number: Int) throws -> ObjectStream? {
        // Like PDFium, an object stream must itself be an ordinary object, not inside another one.
        guard let entry = xref[number], entry.type == 1, let stream = try getObject(number) as? CosStream,
            try resolveName(stream.dict["Type"]) == "ObjStm",
            let count = try resolveNumber(stream.dict["N"]), let first = try resolveNumber(stream.dict["First"]),
            count >= 0, first >= 0 else {
            return nil
        }

        var problem: String?
        guard let data = try decodeStream(stream, &problem), count <= Double(data.count / 4) else {
            return nil
        }

        let lexer = PdfLexer(data)
        var numbers = [Int](repeating: 0, count: DotNetMath.toInt32(count))
        var offsets = [Int](repeating: 0, count: numbers.count)
        for i in 0..<numbers.count {
            let objectNumber = lexer.next()
            let offset = lexer.next()
            if !Self.isCount(objectNumber) || !Self.isCount(offset) || first + offset.number >= Double(data.count) {
                return nil
            }

            numbers[i] = DotNetMath.toInt32(objectNumber.number)
            offsets[i] = DotNetMath.toInt32(offset.number)
        }

        return ObjectStream(data: data, first: DotNetMath.toInt32(first), numbers: numbers, offsets: offsets)
    }

    /// The last occurrence of `pattern` in `data` at or after `from`.
    private static func lastIndex(of pattern: [UInt8], in data: [UInt8], from: Int) -> Int? {
        var i = data.count - pattern.count
        while i >= from {
            if data[i] == pattern[0] && data[i..<(i + pattern.count)].elementsEqual(pattern) {
                return i
            }

            i -= 1
        }

        return nil
    }

    private struct ObjectStream {
        let data: [UInt8]

        let first: Int

        let numbers: [Int]

        let offsets: [Int]
    }

    private struct DerivedKey: Hashable {
        let kind: String

        let number: Int
    }
}
