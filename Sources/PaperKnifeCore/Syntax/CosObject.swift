/// A PDF object (ISO 32000-1, 7.3), as read from a file or a content stream.
class CosObject {}

final class CosNull: CosObject {
    static let instance = CosNull()
}

final class CosBool: CosObject {
    let value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

/// A number, with its original spelling so that it can be written back unchanged.
final class CosNumber: CosObject {
    let value: Double

    let raw: String

    init(_ value: Double, _ raw: String) {
        self.value = value
        self.raw = raw
    }

    var isInteger: Bool { !raw.utf16.contains(0x2E) && abs(value) <= Double(Int32.max) }
}

/// A name without its slash. Escapes are decoded; each byte maps to one char.
final class CosName: CosObject {
    let value: String

    init(_ value: String) {
        self.value = value
    }
}

final class CosString: CosObject {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }
}

final class CosArray: CosObject {
    var items: [CosObject]

    init(_ items: [CosObject]) {
        self.items = items
    }

    var count: Int { items.count }

    /// The item at an index; like C#'s `List` indexer, it throws outside the list.
    subscript(_ index: Int) -> CosObject {
        get throws {
            guard index >= 0 && index < items.count else {
                throw DotNetThrows.listIndexOutOfRange()
            }

            return items[index]
        }
    }
}

final class CosDict: CosObject {
    /// The entries in the order C#'s `Dictionary` enumerates them, which is the order written.
    var entries: OrderedDictionary<String, CosObject>

    init(_ entries: OrderedDictionary<String, CosObject>) {
        self.entries = entries
    }

    subscript(_ key: String) -> CosObject? { entries[key] }
}

final class CosRef: CosObject {
    let number: Int

    let generation: Int

    init(_ number: Int, _ generation: Int) {
        self.number = number
        self.generation = generation
    }
}

/// A stream: its dictionary and where its encoded data lies in the file.
final class CosStream: CosObject {
    let dict: CosDict

    let dataStart: Int

    let dataLength: Int

    init(_ dict: CosDict, _ dataStart: Int, _ dataLength: Int) {
        self.dict = dict
        self.dataStart = dataStart
        self.dataLength = dataLength
    }
}

/// Writes objects in PDF syntax, as Latin-1 text. Strings are written in hexadecimal.
enum CosWriter {
    static func toText(_ value: CosObject) throws -> String {
        var builder = ""
        try write(&builder, value)
        return builder
    }

    static func write(_ builder: inout String, _ value: CosObject) throws {
        switch value {
        case is CosNull:
            builder += "null"
        case let b as CosBool:
            builder += b.value ? "true" : "false"
        case let n as CosNumber:
            builder += n.raw
        case let name as CosName:
            writeName(&builder, name.value)
        case let s as CosString:
            writeHex(&builder, s.bytes)
        case let r as CosRef:
            builder += "\(r.number) \(r.generation) R"
        case let array as CosArray:
            builder += "["
            for i in 0..<array.count {
                if i > 0 {
                    builder += " "
                }

                try write(&builder, array.items[i])
            }

            builder += "]"
        case let dict as CosDict:
            builder += "<<"
            for (key, entry) in dict.entries {
                writeName(&builder, key)
                builder += " "
                try write(&builder, entry)
            }

            builder += ">>"
        default:
            throw DotNetThrows.argument("Streams can't be written inline.", "value")
        }
    }

    static func writeName(_ builder: inout String, _ name: String) {
        builder += "/"
        for c in name.utf16 {
            let b = UInt8(truncatingIfNeeded: c)
            if b < 0x21 || b > 0x7E || b == 0x23 || PdfLexer.isDelimiter(b) {
                builder += "#" + DotNetFormat.x2(b)
            } else {
                // The char itself, which is more than its low byte only for names PaperKnife made.
                builder += String(units: [c])
            }
        }
    }

    static func writeHex<C: Collection>(_ builder: inout String, _ bytes: C) where C.Element == UInt8 {
        builder += "<" + DotNetFormat.hex(bytes) + ">"
    }

    /// A number in plain decimal notation, with at most ten decimals.
    static func number(_ value: Double) -> String {
        let text = DotNetMath.formatUpTo10Decimals(DotNetMath.round(value, 10))
        return text == "-0" ? "0" : text
    }
}
