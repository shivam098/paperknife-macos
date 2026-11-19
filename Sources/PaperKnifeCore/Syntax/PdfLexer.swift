enum PdfTokenKind {
    case end
    case number
    case name
    case string
    case arrayStart
    case arrayEnd
    case dictStart
    case dictEnd
    case keyword
}

struct PdfToken {
    let kind: PdfTokenKind

    let start: Int

    let end: Int

    /// A number's spelling, a decoded name, or a keyword.
    let text: String

    let number: Double

    /// A string's decoded bytes.
    let bytes: [UInt8]?

    init(_ kind: PdfTokenKind, _ start: Int, _ end: Int, _ text: String, number: Double = 0, bytes: [UInt8]? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.number = number
        self.bytes = bytes
    }

    func isKeyword(_ keyword: String) -> Bool { kind == .keyword && text == keyword }
}

/// Splits PDF syntax into tokens (ISO 32000-1, 7.2). Used for files and content streams.
final class PdfLexer {
    let data: [UInt8]

    /// Never negative: C# throws when it reads at a negative position, so callers check first.
    var position: Int

    init(_ data: [UInt8], _ position: Int = 0) {
        precondition(position >= 0, "C# throws IndexOutOfRangeException when it reads here.")
        self.data = data
        self.position = position
    }

    static func isWhitespace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }

    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
            UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    static func isRegular(_ b: UInt8) -> Bool { !isWhitespace(b) && !isDelimiter(b) }

    func skipWhitespaceAndComments() {
        while position < data.count {
            let b = data[position]
            if Self.isWhitespace(b) {
                position += 1
            } else if b == UInt8(ascii: "%") {
                while position < data.count && data[position] != 13 && data[position] != 10 {
                    position += 1
                }
            } else {
                break
            }
        }
    }

    func peek() -> PdfToken {
        let position = position
        let token = next()
        self.position = position
        return token
    }

    func next() -> PdfToken {
        skipWhitespaceAndComments()
        let start = position
        if start >= data.count {
            return PdfToken(.end, start, start, "")
        }

        let b = data[start]
        switch b {
        case UInt8(ascii: "["):
            position += 1
            return PdfToken(.arrayStart, start, position, "[")
        case UInt8(ascii: "]"):
            position += 1
            return PdfToken(.arrayEnd, start, position, "]")
        case UInt8(ascii: "<") where start + 1 < data.count && data[start + 1] == UInt8(ascii: "<"):
            position += 2
            return PdfToken(.dictStart, start, position, "<<")
        case UInt8(ascii: ">") where start + 1 < data.count && data[start + 1] == UInt8(ascii: ">"):
            position += 2
            return PdfToken(.dictEnd, start, position, ">>")
        case UInt8(ascii: "<"):
            return readHexString()
        case UInt8(ascii: "("):
            return readLiteralString()
        case UInt8(ascii: "/"):
            return readName()
        case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ")"), UInt8(ascii: ">"):
            position += 1
            return PdfToken(.keyword, start, position, Latin1.string([b]))
        default:
            return readWord()
        }
    }

    private func readWord() -> PdfToken {
        let start = position
        while position < data.count && Self.isRegular(data[position]) {
            position += 1
        }

        let word = data[start..<position]
        let text = Latin1.string(word)
        if Self.isNumber(word), let value = Self.parseNumber(word) {
            return PdfToken(.number, start, position, text, number: value)
        }

        return PdfToken(.keyword, start, position, text)
    }

    /// An optional sign and digits with at most one decimal point, as C#'s IsNumber checks.
    private static func isNumber(_ text: ArraySlice<UInt8>) -> Bool {
        var i = text.startIndex
        if i < text.endIndex && (text[i] == UInt8(ascii: "+") || text[i] == UInt8(ascii: "-")) {
            i += 1
        }

        var digits = 0
        var dots = 0
        while i < text.endIndex {
            if text[i] >= UInt8(ascii: "0") && text[i] <= UInt8(ascii: "9") {
                digits += 1
            } else if text[i] == UInt8(ascii: ".") && dots == 0 {
                dots += 1
            } else {
                return false
            }

            i += 1
        }

        return digits > 0
    }

    /// `double.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint,
    /// CultureInfo.InvariantCulture, ...)` for text that `isNumber` accepted.
    private static func parseNumber(_ text: ArraySlice<UInt8>) -> Double? {
        // Whole numbers of up to 15 digits are exact as doubles; "-0" is negative zero, as in .NET.
        if text.count <= 16 && !text.contains(UInt8(ascii: ".")) {
            let negative = text.first == UInt8(ascii: "-")
            let digits = text.first == UInt8(ascii: "-") || text.first == UInt8(ascii: "+") ? text.dropFirst() : text
            if digits.count <= 15 {
                var value = 0
                for digit in digits {
                    value = value * 10 + Int(digit) - 0x30
                }

                return negative ? -Double(value) : Double(value)
            }
        }

        return DotNetParse.double(text.map(UInt16.init))
    }

    private func readName() -> PdfToken {
        let start = position
        position += 1
        var name: [UInt8] = []
        while position < data.count && Self.isRegular(data[position]) {
            let b = data[position]
            if b == UInt8(ascii: "#") && position + 2 < data.count && Self.isHexDigit(data[position + 1]) && Self.isHexDigit(data[position + 2]) {
                name.append(UInt8((Self.hexValue(data[position + 1]) << 4) | Self.hexValue(data[position + 2])))
                position += 3
            } else {
                name.append(b)
                position += 1
            }
        }

        return PdfToken(.name, start, position, Latin1.string(name))
    }

    private func readHexString() -> PdfToken {
        let start = position
        position += 1
        var bytes: [UInt8] = []
        var high = -1
        while position < data.count {
            let b = data[position]
            position += 1
            if b == UInt8(ascii: ">") {
                break
            }

            if !Self.isHexDigit(b) {
                continue
            }

            if high < 0 {
                high = Self.hexValue(b)
            } else {
                bytes.append(UInt8((high << 4) | Self.hexValue(b)))
                high = -1
            }
        }

        if high >= 0 {
            bytes.append(UInt8(high << 4))
        }

        return PdfToken(.string, start, position, "", bytes: bytes)
    }

    private func readLiteralString() -> PdfToken {
        // Like PDFium, line ends inside the string are kept as they are.
        let start = position
        position += 1
        var bytes: [UInt8] = []
        var depth = 1
        while position < data.count {
            let b = data[position]
            position += 1
            if b == UInt8(ascii: "\\") {
                if position >= data.count {
                    break
                }

                let e = data[position]
                position += 1
                switch e {
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "r"): bytes.append(13)
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "b"): bytes.append(8)
                case UInt8(ascii: "f"): bytes.append(12)
                case 13:
                    if position < data.count && data[position] == 10 {
                        position += 1
                    }
                case 10:
                    break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(e) - 0x30
                    var n = 0
                    while n < 2 && position < data.count && data[position] >= UInt8(ascii: "0") && data[position] <= UInt8(ascii: "7") {
                        value = value * 8 + Int(data[position]) - 0x30
                        position += 1
                        n += 1
                    }

                    bytes.append(UInt8(truncatingIfNeeded: value))
                default:
                    bytes.append(e)
                }
            } else if b == UInt8(ascii: "(") {
                depth += 1
                bytes.append(b)
            } else if b == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    break
                }

                bytes.append(b)
            } else {
                bytes.append(b)
            }
        }

        return PdfToken(.string, start, position, "", bytes: bytes)
    }

    static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
    }

    static func hexValue(_ b: UInt8) -> Int {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(b) - 0x30
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(b) - 0x61 + 10
        default: return Int(b) - 0x41 + 10
        }
    }
}

/// Reads objects from tokens: arrays, dictionaries and indirect references.
enum PdfObjectParser {
    private static let maxDepth = 100

    /// The next object, or nil at the end of the data or on syntax it doesn't understand.
    static func read(_ lexer: PdfLexer, allowReferences: Bool = true) -> CosObject? {
        fromToken(lexer, lexer.next(), allowReferences: allowReferences, 0)
    }

    static func fromToken(_ lexer: PdfLexer, _ token: PdfToken, allowReferences: Bool, _ depth: Int) -> CosObject? {
        if depth > maxDepth {
            return nil
        }

        switch token.kind {
        case .number:
            let number = CosNumber(token.number, token.text)
            if allowReferences && number.isInteger && number.value >= 0,
                let reference = tryReadReference(lexer, DotNetMath.toInt32(number.value)) {
                return reference
            }

            return number
        case .name:
            return CosName(token.text)
        case .string:
            return CosString(token.bytes!)
        case .arrayStart:
            var items: [CosObject] = []
            while true {
                let next = lexer.next()
                if next.kind == .arrayEnd {
                    return CosArray(items)
                }

                guard let item = fromToken(lexer, next, allowReferences: allowReferences, depth + 1) else {
                    return nil
                }

                items.append(item)
            }
        case .dictStart:
            var entries = OrderedDictionary<String, CosObject>()
            while true {
                let key = lexer.next()
                if key.kind == .dictEnd {
                    return CosDict(entries)
                }

                guard key.kind == .name, let value = fromToken(lexer, lexer.next(), allowReferences: allowReferences, depth + 1) else {
                    return nil
                }

                entries[key.text] = value
            }
        case .keyword:
            switch token.text {
            case "true": return CosBool(true)
            case "false": return CosBool(false)
            case "null": return CosNull.instance
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func tryReadReference(_ lexer: PdfLexer, _ number: Int) -> CosRef? {
        let position = lexer.position
        let generation = lexer.next()
        if generation.kind == .number && generation.number >= 0 && !generation.text.utf16.contains(0x2E)
            && lexer.next().isKeyword("R") {
            return CosRef(number, DotNetMath.toInt32(generation.number))
        }

        lexer.position = position
        return nil
    }
}
