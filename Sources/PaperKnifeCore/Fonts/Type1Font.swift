/// A Type 1 font program (Adobe Type 1 Font Format, 1990), read far enough to tell whether a subset
/// was made from a given full font: its builtin encoding, its decrypted glyph programs
/// (charstrings) and subroutines, and the values that change how glyphs render. Reading is strict:
/// anything outside the usual structure (a repeated key, an unexpected token among the glyphs, a
/// glyph or subroutine defined twice, a multiple master font) makes it refuse the font rather
/// than guess how a renderer would read it. It runs in linear time on bounded input.
final class Type1Font {
    /// The largest cleartext part and whole program PaperKnife reads; real fonts are far smaller.
    static let maxCleartext = 256 * 1024

    static let maxProgram = 4 * 1024 * 1024

    private static let eexecKey = 55665
    private static let charStringKey = 4330
    private static let maxEntries = 65536
    private static let maxTokens = 1 << 20
    private static let maxSteps = 4_000_000

    // Private dictionary values that change how glyphs render (hinting). Fonts that differ in them
    // aren't the same font, even if their outlines match.
    private static let renderingKeys = OrderedSet([
        "BlueValues", "OtherBlues", "FamilyBlues", "FamilyOtherBlues", "BlueScale", "BlueShift", "BlueFuzz",
        "StdHW", "StdVW", "StemSnapH", "StemSnapV", "ForceBold", "LanguageGroup", "RndStemUp", "ExpansionFactor",
    ])

    private init(
        fontName: String, fontMatrix: [Double], paintType: Int, lenIV: Int, encoding: OrderedDictionary<Int, String>,
        usesStandardEncoding: Bool, charStrings: OrderedDictionary<String, [UInt8]>, subrs: [Int: [UInt8]],
        renderingValues: [String: String], program: [UInt8], length1: Int, length2: Int, length3: Int
    ) {
        self.fontName = fontName
        self.fontMatrix = fontMatrix
        self.paintType = paintType
        self.lenIV = lenIV
        self.encoding = encoding
        self.usesStandardEncoding = usesStandardEncoding
        self.charStrings = charStrings
        self.subrs = subrs
        self.renderingValues = renderingValues
        self.program = program
        self.length1 = length1
        self.length2 = length2
        self.length3 = length3
    }

    let fontName: String

    let fontMatrix: [Double]

    /// The scale from glyph space to text space, normally 0.001.
    var scale: Double { fontMatrix[0] > 0 ? fontMatrix[0] : 0.001 }

    let paintType: Int

    /// The number of random bytes before each glyph program; -1 when they aren't encrypted.
    let lenIV: Int

    /// The builtin encoding: glyph names by code. Empty when the font uses StandardEncoding.
    let encoding: OrderedDictionary<Int, String>

    let usesStandardEncoding: Bool

    /// Glyph programs by glyph name, decrypted, without the leading random bytes, in the program's order.
    let charStrings: OrderedDictionary<String, [UInt8]>

    let subrs: [Int: [UInt8]]

    let renderingValues: [String: String]

    /// The program the way a /FontFile stream holds it: cleartext, then the encrypted part, then the trailer.
    let program: [UInt8]

    let length1: Int

    let length2: Int

    let length3: Int

    /// Reads a font in the PFB format Type 1 fonts are distributed in.
    static func fromPfb(_ pfb: ArraySlice<UInt8>) -> Type1Font? {
        if pfb.count > maxProgram + 64 {
            return nil
        }

        let pfb = Array(pfb)
        var clear: [UInt8] = []
        var encrypted: [UInt8] = []
        var trailer: [UInt8] = []
        var at = 0
        while at + 6 <= pfb.count && pfb[at] == 0x80 && (pfb[at + 1] == 1 || pfb[at + 1] == 2) {
            let length = Int(Int32(bitPattern: UInt32(pfb[at + 2]) | UInt32(pfb[at + 3]) << 8 | UInt32(pfb[at + 4]) << 16 | UInt32(pfb[at + 5]) << 24))
            if length < 0 || length > pfb.count - at - 6 {
                return nil
            }

            let segment = pfb[(at + 6)..<(at + 6 + length)]
            if pfb[at + 1] == 2 {
                encrypted += segment
            } else if encrypted.isEmpty {
                clear += segment
            } else {
                trailer += segment
            }

            at += 6 + length
        }

        return parse(clear, encrypted, trailer)
    }

    /// Reads a font embedded in a PDF (/FontFile), whose first two parts have the lengths /Length1 and /Length2.
    static func fromEmbedded(_ data: [UInt8], _ length1: Int, _ length2: Int) -> Type1Font? {
        if data.count > maxProgram || length1 <= 0 || length2 <= 0 || length1 > data.count || length2 > data.count - length1 {
            return nil
        }

        return parse(Array(data[0..<length1]), Array(data[length1..<(length1 + length2)]), Array(data[(length1 + length2)...]))
    }

    /// The builtin encoding of a program from its cleartext part alone: whether it is StandardEncoding,
    /// and otherwise the glyph names by code. Nil when it can't be read.
    static func readEncoding(_ cleartext: [UInt8]) -> (standard: Bool, names: OrderedDictionary<Int, String>)? {
        guard let header = readCleartext(cleartext) else {
            return nil
        }

        return (header.standardEncoding, header.encoding)
    }

    /// The PostScript name a program gives itself in its cleartext part, or nil when it can't be read.
    static func readFontName(_ cleartext: [UInt8]) -> String? { readCleartext(cleartext)?.name }

    /// The advance width of a glyph in text space units (1000 per em for most fonts), or nil.
    func width(_ glyph: String) -> Double? {
        guard let program = charStrings[glyph] else {
            return nil
        }

        // The width comes first, from hsbw (sbx wx) or sbw (sbx sby wx wy), possibly computed with div.
        var stack: [Double] = []
        var i = 0
        while i < program.count {
            let v = Int(program[i])
            i += 1
            if v >= 32 {
                guard let number = CharStringAnalyzer.readNumber(program, v, &i), stack.count < 24 else {
                    return nil
                }

                stack.append(number)
                continue
            }

            switch v {
            case 13:
                return stack.count >= 2 ? stack[1] * scale * 1000 : nil
            case 12 where i < program.count:
                let escaped = program[i]
                i += 1
                if escaped == 7 {
                    return stack.count >= 3 ? stack[2] * scale * 1000 : nil
                }

                if escaped == 12 && stack.count >= 2 && stack[stack.count - 1] != 0 {
                    let quotient = stack[stack.count - 2] / stack[stack.count - 1]
                    stack.removeLast(2)
                    stack.append(quotient)
                    continue
                }

                return nil
            default:
                return nil
            }
        }

        return nil
    }

    /// Why this font, a subset, isn't part of `full`, or nil when it is: same name, matrix, paint
    /// type, glyph encryption and rendering values; every glyph it has is identical in `full`, and
    /// so is every subroutine those glyphs call, directly or not (subsetters replace the
    /// subroutines nothing calls by stubs); the glyphs an accented glyph is built from are there
    /// too; and its encoding maps codes to the same glyphs. Then every glyph it can draw renders
    /// the same with `full`.
    func differenceFrom(_ full: Type1Font) -> String? {
        if Self.baseName(fontName) != Self.baseName(full.fontName) {
            return "it has a different name"
        }

        if fontMatrix != full.fontMatrix || paintType != full.paintType {
            return "its size or style differs"
        }

        if lenIV != full.lenIV {
            return "its glyphs are stored differently"
        }

        for key in Self.renderingKeys where renderingValues[key] != full.renderingValues[key] {
            return "its /\(key) differs"
        }

        if usesStandardEncoding != full.usesStandardEncoding
            || encoding.contains(where: { $0.value != ".notdef" && full.encoding[$0.key] != $0.value }) {
            return "its encoding differs"
        }

        let budget = CharStringAnalyzer.Budget(Self.maxSteps)
        for (name, program) in charStrings {
            guard let other = full.charStrings[name], other == program else {
                return "its glyph “\(name)” differs"
            }

            guard let uses = CharStringAnalyzer.analyze(program, subrs, budget) else {
                return "PaperKnife couldn't follow its glyph “\(name)”"
            }

            for index in uses.subrs {
                guard let subroutine = full.subrs[index], subroutine == subrs[index] else {
                    return "its subroutine \(index) differs"
                }
            }

            for code in uses.components {
                guard let component = Encodings.standardName(code), charStrings.contains(key: component) else {
                    return "its glyph “\(name)” is built from a glyph it doesn't have"
                }
            }
        }

        return nil
    }

    /// A font name without the six-letter subset tag ("ABCDEF+CMR10" is "CMR10").
    static func baseName(_ name: String) -> String {
        let units = name.units
        if units.count > 7 && units[6] == 0x2B && !units[0..<6].contains(where: { $0 < 0x41 || $0 > 0x5A }) {
            return String(units: units[7...])
        }

        return name
    }

    /// Type 1 decryption (section 7.1): eexec uses key 55665, charstrings 4330; `skip` leading bytes are random.
    static func decrypt(_ data: ArraySlice<UInt8>, _ key: Int, _ skip: Int) -> [UInt8] {
        var plain = [UInt8](repeating: 0, count: data.count)
        data.withUnsafeBufferPointer { cipher in
            plain.withUnsafeMutableBufferPointer { output in
                // C# computes this in 32 bits; only the low 16 bits are kept either way.
                var r = UInt32(truncatingIfNeeded: key)
                for i in 0..<cipher.count {
                    let c = cipher[i]
                    output[i] = c ^ UInt8(truncatingIfNeeded: r >> 8)
                    r = ((UInt32(c) &+ r) &* 52845 &+ 22719) & 0xFFFF
                }
            }
        }

        return skip >= plain.count ? [] : Array(plain[skip...])
    }

    private static func parse(_ clear: [UInt8], _ encrypted: [UInt8], _ trailer: [UInt8]) -> Type1Font? {
        guard clear.count <= maxCleartext, clear.count + encrypted.count + trailer.count <= maxProgram, let header = readCleartext(clear) else {
            return nil
        }

        let plain = decrypt(isHex(encrypted) ? fromHex(encrypted)[...] : encrypted[...], eexecKey, 4)
        guard let tokens = PostScriptTokenizer.tokenize(plain, maxTokens, "closefile") else {
            return nil
        }

        // Each key once, and /lenIV before the glyphs it applies to, as renderers read them in order.
        var lenIVAt = -1
        var subrsAt = -1
        var charStringsAt = -1
        var lenIV = 4
        var values: [String: String] = [:]
        for k in 0..<tokens.count where tokens[k].kind == .name {
            let key = tokens[k].text(plain)
            switch key {
            case "/lenIV":
                guard lenIVAt < 0, k + 1 < tokens.count, let iv = signedInteger(plain, tokens[k + 1]), iv >= -1 && iv <= 32 else {
                    return nil
                }

                lenIVAt = k
                lenIV = iv
            case "/Subrs":
                if subrsAt >= 0 {
                    return nil
                }

                subrsAt = k
            case "/CharStrings":
                if charStringsAt >= 0 {
                    return nil
                }

                charStringsAt = k
            default:
                let name = key.substring(1)
                if renderingKeys.contains(name) {
                    if values[name] != nil {
                        return nil
                    }

                    values[name] = readValue(plain, tokens, k + 1)
                }
            }
        }

        if charStringsAt < 0 || (lenIVAt >= 0 && (lenIVAt > charStringsAt || (subrsAt >= 0 && lenIVAt > subrsAt))) {
            return nil
        }

        let subrs: [Int: [UInt8]]? = subrsAt < 0 ? [:] : readSubrs(plain, tokens, subrsAt + 1, lenIV)
        let charStrings = readCharStrings(plain, tokens, charStringsAt + 1, lenIV)
        guard let subrs, let charStrings else {
            return nil
        }

        return Type1Font(
            fontName: header.name, fontMatrix: header.matrix, paintType: header.paintType, lenIV: lenIV, encoding: header.encoding,
            usesStandardEncoding: header.standardEncoding, charStrings: charStrings, subrs: subrs, renderingValues: values,
            program: clear + encrypted + trailer, length1: clear.count, length2: encrypted.count, length3: trailer.count)
    }

    private struct Cleartext {
        let name: String

        let matrix: [Double]

        let paintType: Int

        let standardEncoding: Bool

        let encoding: OrderedDictionary<Int, String>
    }

    private static func readCleartext(_ clear: [UInt8]) -> Cleartext? {
        guard clear.count <= maxCleartext, let tokens = PostScriptTokenizer.tokenize(clear, maxTokens, "eexec") else {
            return nil
        }

        var name: String?
        var matrix: [Double]?
        var paintType: Int?
        var encoding: (standard: Bool, names: OrderedDictionary<Int, String>)?
        for k in 0..<tokens.count where tokens[k].kind == .name {
            switch tokens[k].text(clear) {
            case "/FontName":
                guard name == nil, k + 1 < tokens.count, tokens[k + 1].kind == .name else {
                    return nil
                }

                name = tokens[k + 1].text(clear).substring(1)
            case "/FontMatrix":
                guard matrix == nil, let m = readMatrix(clear, tokens, k + 1) else {
                    return nil
                }

                matrix = m
            case "/PaintType":
                guard paintType == nil, k + 1 < tokens.count, let paint = tokens[k + 1].integer(clear) else {
                    return nil
                }

                paintType = paint
            case "/FontType":
                if k + 1 >= tokens.count || tokens[k + 1].integer(clear) != 1 {
                    return nil
                }
            case "/Encoding":
                guard encoding == nil, let read = readBuiltinEncoding(clear, tokens, k + 1) else {
                    return nil
                }

                encoding = read
            case "/WeightVector", "/BlendDesignPositions", "/BlendDesignMap", "/BlendAxisTypes", "/Blend":
                // Multiple master fonts render through instances PaperKnife doesn't model.
                return nil
            default:
                break
            }
        }

        guard let name, let matrix, let e = encoding else {
            return nil
        }

        return Cleartext(name: name, matrix: matrix, paintType: paintType ?? 0, standardEncoding: e.standard, encoding: e.names)
    }

    // [a b c d e f]
    private static func readMatrix(_ data: [UInt8], _ tokens: [PsToken], _ k: Int) -> [Double]? {
        if k + 7 >= tokens.count || tokens[k].kind != .arrayStart || tokens[k + 7].kind != .arrayEnd {
            return nil
        }

        var matrix = [Double](repeating: 0, count: 6)
        for i in 0..<6 {
            let token = tokens[k + 1 + i]
            guard token.kind == .regular, let value = DotNetParse.double(token.text(data).utf16), value.isFinite else {
                return nil
            }

            matrix[i] = value
        }

        return matrix
    }

    // "StandardEncoding def", or "256 array ... dup <code> /<name> put ... def" (with anything that
    // isn't a name in between, such as the loop that fills the array with .notdef).
    private static func readBuiltinEncoding(_ data: [UInt8], _ tokens: [PsToken], _ k: Int) -> (standard: Bool, names: OrderedDictionary<Int, String>)? {
        var names = OrderedDictionary<Int, String>()
        if k < tokens.count && tokens[k].is(data, "StandardEncoding") {
            return (true, names)
        }

        if k + 1 >= tokens.count || tokens[k].integer(data) == nil || !tokens[k + 1].is(data, "array") {
            return nil
        }

        var j = k + 2
        while j < tokens.count {
            if tokens[j].is(data, "def") {
                return (false, names)
            }

            if tokens[j].is(data, "dup") && j + 3 < tokens.count, let code = tokens[j + 1].integer(data), code < 256,
                tokens[j + 2].kind == .name, tokens[j + 3].is(data, "put") {
                names[code] = tokens[j + 2].text(data).substring(1)
                j += 3
            } else if tokens[j].kind == .name {
                return nil
            }

            j += 1
        }

        return nil
    }

    // "count array", then "dup <index> <length> RD <binary> NP" for each.
    private static func readSubrs(_ data: [UInt8], _ tokens: [PsToken], _ k: Int, _ lenIV: Int) -> [Int: [UInt8]]? {
        guard k + 1 < tokens.count, let count = tokens[k].integer(data), count <= maxEntries, tokens[k + 1].is(data, "array") else {
            return nil
        }

        var subrs: [Int: [UInt8]] = [:]
        var j = k + 2
        while j < tokens.count && tokens[j].is(data, "dup") {
            guard j + 5 < tokens.count, let index = tokens[j + 1].integer(data), index < count,
                let program = readProgram(data, tokens, j + 2, lenIV), subrs[index] == nil else {
                return nil
            }

            subrs[index] = program
            j += 5
            if tokens[j].is(data, "NP") || tokens[j].is(data, "|") {
                j += 1
            } else if j + 1 < tokens.count && tokens[j].is(data, "noaccess") && tokens[j + 1].is(data, "put") {
                j += 2
            } else {
                return nil
            }
        }

        return subrs
    }

    // "count dict dup begin", then "/<name> <length> RD <binary> ND" for each, then "end".
    private static func readCharStrings(_ data: [UInt8], _ tokens: [PsToken], _ k: Int, _ lenIV: Int) -> OrderedDictionary<String, [UInt8]>? {
        guard k + 3 < tokens.count, let count = tokens[k].integer(data), count <= maxEntries, tokens[k + 1].is(data, "dict"),
            tokens[k + 2].is(data, "dup"), tokens[k + 3].is(data, "begin") else {
            return nil
        }

        var glyphs = OrderedDictionary<String, [UInt8]>()
        var j = k + 4
        while j < tokens.count && !tokens[j].is(data, "end") {
            guard tokens[j].kind == .name, j + 4 < tokens.count, let program = readProgram(data, tokens, j + 1, lenIV),
                glyphs.tryAdd(tokens[j].text(data).substring(1), program), glyphs.count <= count else {
                return nil
            }

            j += 4
            if tokens[j].is(data, "ND") || tokens[j].is(data, "|-") {
                j += 1
            } else if j + 1 < tokens.count && tokens[j].is(data, "noaccess") && tokens[j + 1].is(data, "def") {
                j += 2
            } else {
                return nil
            }
        }

        return j < tokens.count && glyphs.count > 0 ? glyphs : nil
    }

    // "<length> RD <binary>", decrypted.
    private static func readProgram(_ data: [UInt8], _ tokens: [PsToken], _ k: Int, _ lenIV: Int) -> [UInt8]? {
        let binary = tokens[k + 2]
        guard let length = tokens[k].integer(data), tokens[k + 1].is(data, "RD") || tokens[k + 1].is(data, "-|"),
            binary.kind == .binary, binary.length == length else {
            return nil
        }

        let raw = data[binary.start..<(binary.start + binary.length)]
        return lenIV < 0 ? Array(raw) : decrypt(raw, charStringKey, lenIV)
    }

    // The tokens of a value up to the operator that stores it, such as "[ -22 0 683 705 ]".
    private static func readValue(_ data: [UInt8], _ tokens: [PsToken], _ k: Int) -> String {
        var parts: [String] = []
        var j = k
        while j < tokens.count && parts.count < 64 {
            let token = tokens[j]
            let text = token.text(data)
            if token.kind == .name
                || (token.kind == .regular && ["def", "ND", "|-", "readonly", "noaccess", "executeonly", "put"].contains(text)) {
                break
            }

            parts.append(text)
            j += 1
        }

        return parts.joined(separator: " ")
    }

    private static func signedInteger(_ data: [UInt8], _ token: PsToken) -> Int? {
        token.kind == .regular && token.length <= 10 ? DotNetParse.signedInt32(token.text(data).utf16) : nil
    }

    private static func isHex(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data[0..<4].allSatisfy(PdfLexer.isHexDigit)
    }

    private static func fromHex(_ data: [UInt8]) -> [UInt8] {
        let digits = data.filter(PdfLexer.isHexDigit)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var i = 0
        while i + 1 < digits.count {
            bytes.append(UInt8(PdfLexer.hexValue(digits[i]) << 4 | PdfLexer.hexValue(digits[i + 1])))
            i += 2
        }

        return bytes
    }
}
