/// A new version of an object, written by `IncrementalUpdate`.
class ObjectUpdate {
    let number: Int

    let generation: Int

    init(_ number: Int, _ generation: Int) {
        self.number = number
        self.generation = generation
    }
}

/// A new version of a stream object, with its decoded data. It is written compressed, with
/// `entries` (for example a font program's /Length1) added to its dictionary.
final class StreamUpdate: ObjectUpdate {
    let data: [UInt8]

    let entries: OrderedDictionary<String, CosObject>?

    init(_ number: Int, _ generation: Int, _ data: [UInt8], _ entries: OrderedDictionary<String, CosObject>? = nil) {
        self.data = data
        self.entries = entries
        super.init(number, generation)
    }
}

/// A new version of an object that isn't a stream, such as a dictionary.
final class ValueUpdate: ObjectUpdate {
    let value: CosObject

    init(_ number: Int, _ generation: Int, _ value: CosObject) {
        self.value = value
        super.init(number, generation)
    }
}

/// Appends an incremental update to a PDF (ISO 32000-1, 7.5.6): new versions of some objects and a
/// cross-reference section pointing to them. Every byte of the original file stays as it was.
enum IncrementalUpdate {
    private typealias Entry = (number: Int, generation: Int, offset: Int)

    static func append(_ file: PdfFile, _ updates: [ObjectUpdate]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(file.data.count + updates.reduce(0) { $0 + (($1 as? StreamUpdate)?.data.count ?? 0) / 2 } + 1024)
        output.append(contentsOf: file.data)
        guard let last = file.data.last else {
            throw DotNetThrows.indexOutOfRange()
        }

        if last != 10 && last != 13 {
            write(&output, "\n")
        }

        var entries: [Entry] = []
        for update in updates.stableSorted(by: { $0.number < $1.number }) {
            entries.append((update.number, update.generation, output.count))
            var text = "\(update.number) \(update.generation) obj\n"
            switch update {
            case let stream as StreamUpdate:
                let data = try StreamFilters.deflate(stream.data[...])
                text += "<</Length \(data.count)/Filter/FlateDecode"
                for (key, value) in stream.entries ?? OrderedDictionary() {
                    CosWriter.writeName(&text, key)
                    text += " "
                    try CosWriter.write(&text, value)
                }

                text += ">>\nstream\n"
                write(&output, text)
                output.append(contentsOf: data)
                write(&output, "\nendstream\nendobj\n")
            case let value as ValueUpdate:
                try CosWriter.write(&text, value.value)
                text += "\nendobj\n"
                write(&output, text)
            default:
                break
            }
        }

        guard let highest = entries.map(\.number).max() else {
            throw DotNetThrows.noElements()
        }

        // C# adds in 32 bits.
        let size = max(file.size, Int(Int32(truncatingIfNeeded: highest) &+ 1))
        if file.hasXrefStream {
            try writeXrefStream(&output, file, entries, size)
        } else {
            try writeXrefTable(&output, file, entries, size)
        }

        return output
    }

    private static func writeXrefTable(_ output: inout [UInt8], _ file: PdfFile, _ entries: [Entry], _ size: Int) throws {
        let start = output.count
        var text = "xref\n"
        for (number, generation, offset) in entries {
            text += "\(number) 1\n\(DotNetFormat.d(offset, 10)) \(DotNetFormat.d(generation, 5)) n\r\n"
        }

        text += "trailer\n"
        try CosWriter.write(&text, trailer(file, size))
        text += "\nstartxref\n\(start)\n%%EOF\n"
        write(&output, text)
    }

    private static func writeXrefStream(_ output: inout [UInt8], _ file: PdfFile, _ entries: [Entry], _ size: Int) throws {
        // The cross-reference stream is a new object, listed in itself.
        let number = size
        let start = output.count
        var all = entries
        all.append((number, 0, start))
        let offsetWidth = all.map(\.offset).max()! > Int(UInt32.max) ? 8 : 4
        var data = [UInt8](repeating: 0, count: all.count * (1 + offsetWidth + 2))
        var at = 0
        for (_, generation, offset) in all {
            data[at] = 1
            at += 1
            for i in stride(from: offsetWidth - 1, through: 0, by: -1) {
                data[at] = UInt8(truncatingIfNeeded: offset >> (8 * i))
                at += 1
            }

            data[at] = UInt8(truncatingIfNeeded: generation >> 8)
            data[at + 1] = UInt8(truncatingIfNeeded: generation)
            at += 2
        }

        let dict = trailer(file, Int(Int32(truncatingIfNeeded: number) &+ 1))
        dict.entries["Type"] = CosName("XRef")
        dict.entries["Index"] = CosArray(all.flatMap { [integer($0.number), integer(1)] })
        dict.entries["W"] = CosArray([integer(1), integer(offsetWidth), integer(2)])
        dict.entries["Length"] = integer(data.count)
        var text = "\(number) 0 obj\n"
        try CosWriter.write(&text, dict)
        text += "\nstream\n"
        write(&output, text)
        output.append(contentsOf: data)
        write(&output, "\nendstream\nendobj\nstartxref\n\(start)\n%%EOF\n")
    }

    private static func trailer(_ file: PdfFile, _ size: Int) -> CosDict {
        var entries = OrderedDictionary<String, CosObject>()
        entries["Size"] = integer(size)
        let dict = CosDict(entries)
        for key in ["Root", "Info", "ID"] {
            if let value = file.trailer[key] {
                dict.entries[key] = value
            }
        }

        dict.entries["Prev"] = CosNumber(Double(file.startXref), String(file.startXref))
        return dict
    }

    private static func integer(_ value: Int) -> CosNumber { CosNumber(Double(value), String(value)) }

    private static func write(_ output: inout [UInt8], _ text: String) {
        output.append(contentsOf: Latin1.bytes(text))
    }
}
