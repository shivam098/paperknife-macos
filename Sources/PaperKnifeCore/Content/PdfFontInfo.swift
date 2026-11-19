/// What PaperKnife needs to know about a font to read and write its character codes: how codes
/// are split, their advance widths (as PDFium computes them), what text each code stands for, and,
/// for Type 3 fonts, which codes have a glyph.
final class PdfFontInfo {
    private static let maxMappedCodes = 1 << 17

    // Text by code from glyph names, for the codes the ToUnicode map lacks.
    private var namedText = OrderedDictionary<UInt32, String>()
    private var glyphNames = OrderedDictionary<UInt32, String>()

    // The codes the font's /Differences name.
    private var differenceCodes = Set<UInt32>()
    private var charProcs: Set<String>?
    private var simpleWidths: [Int]?
    private var cidWidths: [UInt32: Int]?
    private var defaultCidWidth = 1000

    // The ToUnicode map, shared with every font that uses it and never changed.
    private var toUnicodeMap: OrderedDictionary<UInt32, String>?

    // The codes for each text (by its UTF-16 code units, as C# compares strings), built when an edit
    // first needs them.
    private var codesByText: [[UInt16]: [UInt32]]?

    private init(_ subtype: String, _ codeLength: Int) {
        self.subtype = subtype
        self.codeLength = codeLength
    }

    let subtype: String

    /// Bytes per character code: 1 for simple fonts, 2 for Identity-H fonts, 0 when not supported.
    let codeLength: Int

    var isType3: Bool { subtype == "Type3" }

    /// - Parameter builtinEncoding: The glyph names of the font program's own encoding, when the
    ///   caller knows them; otherwise they are read from an embedded Type 1 program when PDFium uses them.
    static func load(_ file: PdfFile, _ font: CosDict, _ builtinEncoding: ((Int) -> String?)? = nil) throws -> PdfFontInfo {
        let subtype = try file.resolveName(font["Subtype"]) ?? ""
        let info: PdfFontInfo
        if subtype == "Type0" {
            let identity = (try file.resolve(font["Encoding"]) as? CosName)?.value == "Identity-H"
            var type0 = PdfFontInfo(subtype, identity ? 2 : 0)
            var first: CosObject?
            if let descendants = try file.resolveArray(font["DescendantFonts"]), descendants.count > 0 {
                first = descendants.items[0]
            }

            if let descendant = try file.resolveDict(first) {
                let defaultWidth = try DotNetMath.toInt32(file.resolveNumber(descendant["DW"]) ?? 1000)
                type0 = PdfFontInfo(subtype, identity ? 2 : 0, defaultWidth, try cidWidths(file, file.resolveArray(descendant["W"])))
            }

            info = type0
        } else {
            info = try PdfFontInfo(subtype, 1, file, font, builtinEncoding)
        }

        info.toUnicodeMap = try toUnicode(file, font["ToUnicode"])
        for (code, name) in info.glyphNames {
            if info.toUnicodeMap?.contains(key: code) != true, let text = Encodings.glyphToUnicode(name) {
                info.namedText[code] = text
            }
        }

        return info
    }

    private convenience init(_ subtype: String, _ codeLength: Int, _ defaultWidth: Int, _ widths: [UInt32: Int]?) {
        self.init(subtype, codeLength)
        defaultCidWidth = defaultWidth
        cidWidths = widths
    }

    private convenience init(_ subtype: String, _ codeLength: Int, _ file: PdfFile, _ font: CosDict, _ builtinEncoding: ((Int) -> String?)?) throws {
        self.init(subtype, codeLength)
        try Self.readGlyphNames(file, font, subtype, &glyphNames, &differenceCodes, builtinEncoding)
        if subtype == "Type3" {
            charProcs = try file.resolveDict(font["CharProcs"]).map { Set($0.entries.keys) }
        }

        guard let widths = try file.resolveArray(font["Widths"]) else {
            return
        }

        // Mirrors PDFium: Type 3 widths are scaled by the font matrix and rounded; other simple
        // fonts take whole numbers, and codes outside the array take /MissingWidth if present.
        var simple = [Int](repeating: -1, count: 256)
        defer {
            simpleWidths = simple
        }

        let first = try DotNetMath.toInt32(file.resolveNumber(font["FirstChar"]) ?? 0)
        if first < 0 || first > 255 {
            return
        }

        if subtype == "Type3" {
            var scale = 0.001
            if let matrix = try file.resolveArray(font["FontMatrix"]), matrix.count == 6 {
                scale = try file.resolveNumber(matrix.items[0]) ?? 0.001
            }

            var i = 0
            while i < widths.count && first + i < 256 {
                let width = try DotNetMath.toInt32(DotNetMath.roundAwayFromZero((file.resolveNumber(widths.items[i]) ?? 0) * scale * 1000))
                simple[first + i] = width == 0 ? -1 : width
                i += 1
            }

            return
        }

        if let missing = try file.resolveNumber(file.resolveDict(font["FontDescriptor"])?["MissingWidth"]) {
            simple = [Int](repeating: DotNetMath.toInt32(missing), count: 256)
        }

        var last = try DotNetMath.toInt32(file.resolveNumber(font["LastChar"]) ?? 0)
        if last == 0 || last >= first + widths.count {
            last = first + widths.count - 1
        }

        var code = first
        while code <= min(last, 255) {
            simple[code] = try DotNetMath.toInt32(file.resolveNumber(widths.items[code - first]) ?? 0)
            code += 1
        }
    }

    /// The advance width of a code for a font size of 1, or nil when PaperKnife can't tell it.
    func width(_ code: UInt32) -> Double? {
        if let cidWidths {
            return Double(cidWidths[code] ?? defaultCidWidth) / 1000.0
        }

        if let simpleWidths, code < 256, simpleWidths[Int(code)] >= 0 {
            return Double(simpleWidths[Int(code)]) / 1000.0
        }

        return nil
    }

    func unicode(_ code: UInt32) -> String? {
        if let toUnicodeMap, let text = toUnicodeMap[code] {
            return text
        }

        return namedText[code]
    }

    /// The name of the glyph a code selects, when the font selects glyphs by name and PaperKnife knows it.
    func glyphName(_ code: UInt32) -> String? { glyphNames[code] }

    /// Whether the font itself says a code draws `text`, with that glyph's width, for a font that
    /// selects glyphs by name. It does for a code its /Differences name, or any code if it has
    /// none: PDFium draws the glyph the PDF names. pdfTeX names only the codes a document uses,
    /// though; at the others PDFium draws the glyph the program's own encoding gives them, if the
    /// subset has it for another code or font, and pdfTeX's width and character map follow TeX's
    /// encoding. There only the character map can vouch, when that glyph stands for the same character.
    func vouches(_ code: UInt32, _ text: String) throws -> Bool {
        if differenceCodes.isEmpty || differenceCodes.contains(code) {
            return true
        }

        guard toUnicodeMap?.contains(key: code) == true, let name = glyphName(code), let own = Encodings.glyphToUnicode(name) else {
            return false
        }

        return try Self.comparable(own).ordinalEquals(Self.comparable(text))
    }

    /// Whether a code draws a glyph. Only Type 3 fonts can tell; for others it is checked elsewhere.
    func hasGlyph(_ code: UInt32) -> Bool {
        guard let charProcs else {
            return true
        }

        guard let name = glyphNames[code] else {
            return false
        }

        return charProcs.contains(name)
    }

    func splitCodes<C: Collection>(_ bytes: C) -> [UInt32] where C.Element == UInt8 {
        let bytes = Array(bytes)
        var codes: [UInt32] = []
        codes.reserveCapacity(bytes.count)
        if codeLength == 2 {
            var i = 0
            while i + 1 < bytes.count {
                codes.append(UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]))
                i += 2
            }
        } else {
            for b in bytes {
                codes.append(UInt32(b))
            }
        }

        return codes
    }

    /// The bytes of the codes; like C#, it throws for a font whose codes it can't write (code length 0).
    func joinCodes(_ codes: [UInt32]) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: codes.count * codeLength)
        for i in 0..<codes.count {
            if codeLength == 2 {
                bytes[2 * i] = UInt8(truncatingIfNeeded: codes[i] >> 8)
                bytes[2 * i + 1] = UInt8(truncatingIfNeeded: codes[i])
            } else {
                guard i < bytes.count else {
                    throw DotNetThrows.indexOutOfRange()
                }

                bytes[i] = UInt8(truncatingIfNeeded: codes[i])
            }
        }

        return bytes
    }

    /// Character codes that draw `text`, preferring codes already used nearby. Characters without a
    /// code are reported in `missing`: each UTF-16 code unit, as C# iterates chars.
    func encode(_ text: String, _ preferred: Set<UInt32>, _ missing: inout [String]) -> [UInt32] {
        var codes: [UInt32] = []
        codes.reserveCapacity(text.length)
        missing = []
        var missingUnits: [UInt16] = []
        for c in text.utf16 {
            var candidates = codesFor([c])
            if candidates.isEmpty && (c == 0x20 || c == 0xA0) {
                // Fonts often map their one space glyph to only one of the two.
                candidates = codesFor(c == 0x20 ? [0xA0] : [0x20])
            }

            let usable = candidates.filter(hasGlyph)
            if usable.isEmpty {
                if !missingUnits.contains(c) {
                    missingUnits.append(c)
                    missing.append(String(units: [c]))
                }

                continue
            }

            codes.append(choose(usable, preferred))
        }

        return codes
    }

    /// The lowest code that stands for `text`, the one PDFium's reverse lookup finds.
    func firstCodeFor(_ text: String) -> UInt32? { codesFor(text.units).first }

    /// A code whose one glyph draws all of `text` (for example a ligature), preferring `preferred`.
    func codeFor(_ text: String, _ preferred: Set<UInt32>) -> UInt32? {
        let usable = codesFor(text.units).filter(hasGlyph)
        return usable.isEmpty ? nil : choose(usable, preferred)
    }

    /// Of the codes that stand for a text, one already used nearby, or else the lowest one the font
    /// names itself (in /Differences or its character map) rather than through its program's own
    /// encoding alone, whose width may be for another glyph (see `vouches`).
    private func choose(_ usable: [UInt32], _ preferred: Set<UInt32>) -> UInt32 {
        usable.first(where: preferred.contains)
            ?? usable.first(where: { differenceCodes.contains($0) || toUnicodeMap?.contains(key: $0) == true })
            ?? usable[0]
    }

    private func codesFor(_ text: [UInt16]) -> [UInt32] {
        if codesByText == nil {
            codesByText = indexCodes()
        }

        return codesByText?[text] ?? []
    }

    /// The codes that stand for each text, lowest first. Only edits need them, so viewing a page doesn't build them.
    private func indexCodes() -> [[UInt16]: [UInt32]] {
        var index: [[UInt16]: [UInt32]] = [:]
        func add(_ text: [UInt16], _ code: UInt32) {
            index[text, default: []].append(code)
        }

        var texts: [(key: UInt32, value: String)] = []
        if let toUnicodeMap {
            texts += toUnicodeMap.map { $0 }
        }

        texts += namedText.map { $0 }
        for (code, text) in texts.stableSorted(by: { $0.key < $1.key }) {
            add(text.units, code)

            // PDFium reads the ligatures U+FB00 to U+FB06 as their letters, for example "fi".
            let expanded = Encodings.expandLigatures(text)
            if !expanded.ordinalEquals(text) {
                add(expanded.units, code)
            }
        }

        return index
    }

    private static func readGlyphNames(
        _ file: PdfFile, _ font: CosDict, _ subtype: String, _ names: inout OrderedDictionary<UInt32, String>,
        _ differenceCodes: inout Set<UInt32>, _ builtin: ((Int) -> String?)?
    ) throws {
        var baseEncoding: String?
        var differences: CosArray?
        let encoding = try file.resolve(font["Encoding"])
        if let name = encoding as? CosName {
            baseEncoding = name.value
        } else if let dict = encoding as? CosDict {
            baseEncoding = try file.resolveName(dict["BaseEncoding"])
            differences = try file.resolveArray(dict["Differences"])
        }

        let baseFont = try file.resolveName(font["BaseFont"]) ?? ""
        let table: ((Int) -> String?)?
        if subtype == "Type1" || subtype == "MMType1" {
            table = try type1BaseEncoding(file, font, encoding, baseFont, builtin)
        } else if let predefined = predefined(baseEncoding) {
            table = predefined
        } else {
            table = baseEncoding == "StandardEncoding" ? Encodings.standardName : nil
        }

        if let table {
            for code in 0..<256 {
                if let name = table(code) {
                    names[UInt32(code)] = name
                }
            }
        }

        var next = 0
        for item in differences?.items ?? [] {
            if let number = item as? CosNumber {
                next = DotNetMath.toInt32(number.value)
            } else if let name = item as? CosName, next >= 0 && next < 256 {
                differenceCodes.insert(UInt32(next))
                names[UInt32(next)] = name.value
                next += 1
            }
        }
    }

    /// The encoding PDFium starts from for a Type 1 font (cpdf_simplefont.cpp, LoadCommon and
    /// LoadPDFEncoding): StandardEncoding for a nonsymbolic font, and for a symbolic one the
    /// encoding of its embedded program, or WinAnsiEncoding when it isn't embedded. A named
    /// encoding replaces that, except StandardEncoding, which PDFium ignores. Nil when unknown.
    private static func type1BaseEncoding(
        _ file: PdfFile, _ font: CosDict, _ encoding: CosObject?, _ baseFont: String, _ builtin: ((Int) -> String?)?
    ) throws -> ((Int) -> String?)? {
        let descriptor = try file.resolveDict(font["FontDescriptor"])
        if baseFont.ordinalContains("Symbol") || baseFont.ordinalContains("Dingbats") {
            // PDFium has encodings of its own for these.
            return predefined((encoding as? CosName)?.value)
        }

        let symbolic = try (DotNetMath.toInt32(file.resolveNumber(descriptor?["Flags"]) ?? 0) & 4) != 0
        let embedded = descriptor.map { ($0["FontFile"] ?? $0["FontFile2"] ?? $0["FontFile3"]) != nil } ?? false
        if encoding == nil {
            if !embedded && symbolic {
                return Encodings.winAnsiName
            }
        } else if let name = encoding as? CosName {
            if isPredefinedBase(name.value) {
                // PDFium reads MacExpertEncoding here as WinAnsiEncoding; it has no table of PDFDocEncoding names.
                return name.value == "MacExpertEncoding" ? Encodings.winAnsiName : predefined(name.value)
            }
        } else if let dict = encoding as? CosDict {
            let base = try file.resolveName(dict["BaseEncoding"])
            if let base, isPredefinedBase(base) {
                return predefined(base)
            }

            if !embedded && symbolic {
                return Encodings.standardName
            }
        }

        // Fonts whose program PaperKnife can't read are taken to use StandardEncoding.
        if !symbolic {
            return Encodings.standardName
        }

        if let builtin {
            return builtin
        }

        return try embeddedEncoding(file, descriptor) ?? Encodings.standardName
    }

    private static func isPredefinedBase(_ name: String) -> Bool {
        name == "WinAnsiEncoding" || name == "MacRomanEncoding" || name == "MacExpertEncoding" || name == "PDFDocEncoding"
    }

    // Text as glyph names and character maps are compared (as FontCompletion does).
    private static func comparable(_ text: String) throws -> String {
        try DotNetNormalization.formKC(text).ordinalReplacing("\u{A0}", with: " ")
    }

    private static func predefined(_ name: String?) -> ((Int) -> String?)? {
        if name == "WinAnsiEncoding" {
            return Encodings.winAnsiName
        }

        if name == "MacRomanEncoding" {
            return Encodings.macRomanName
        }

        return nil
    }

    /// The builtin encoding of an embedded Type 1 program, from its cleartext part alone. Read once
    /// per program, however many fonts share it.
    private static func embeddedEncoding(_ file: PdfFile, _ descriptor: CosDict?) throws -> ((Int) -> String?)? {
        let entry = descriptor?["FontFile"]
        func read() throws -> ((Int) -> String?)? {
            guard let stream = try file.resolve(entry) as? CosStream, let length1 = try file.resolveNumber(stream.dict["Length1"]),
                length1 >= 1 && length1 <= Double(Type1Font.maxCleartext),
                let cleartext = try file.decodeStreamPrefix(stream, DotNetMath.toInt32(length1), Type1Font.maxProgram),
                let encoding = Type1Font.readEncoding(cleartext) else {
                return nil
            }

            // A program that says it uses StandardEncoding gets every code of it, as in PDFium.
            if encoding.standard {
                return Encodings.fullStandardName
            }

            let names = encoding.names
            return { code in names[code] }
        }

        if let reference = entry as? CosRef {
            return try file.derived("Type1Encoding", reference.number, read)
        }

        return try read()
    }

    /// A ToUnicode map by code, read once per map, however many fonts share it.
    static func toUnicode(_ file: PdfFile, _ entry: CosObject?) throws -> OrderedDictionary<UInt32, String>? {
        func read() throws -> OrderedDictionary<UInt32, String>? {
            guard let stream = try file.resolve(entry) as? CosStream, let data = try file.decodeStream(stream) else {
                return nil
            }

            var map = OrderedDictionary<UInt32, String>()
            readToUnicode(data, &map)
            return map
        }

        if let reference = entry as? CosRef {
            return try file.derived("ToUnicode", reference.number, read)
        }

        return try read()
    }

    /// The widths in a /W array, or nil when it is too large to read, so they count as unknown.
    private static func cidWidths(_ file: PdfFile, _ array: CosArray?) throws -> [UInt32: Int]? {
        var widths: [UInt32: Int] = [:]
        guard let array else {
            return widths
        }

        // Counts steps rather than entries, so repeated ranges can't make this run for minutes.
        var budget = 2 * maxMappedCodes
        var i = 0
        while i + 1 < array.count {
            if budget <= 0 {
                return nil
            }

            let first = try DotNetMath.toUInt32(file.resolveNumber(array.items[i]) ?? 0)
            if let list = try file.resolve(array.items[i + 1]) as? CosArray {
                var j = 0
                while j < list.count && postDecrement(&budget) > 0 {
                    let width = try DotNetMath.toInt32(file.resolveNumber(list.items[j]) ?? 0)
                    let code = first &+ UInt32(j)
                    if widths[code] == nil {
                        widths[code] = width
                    }

                    j += 1
                }

                i += 2
            } else if i + 2 < array.count {
                let last = try DotNetMath.toUInt32(file.resolveNumber(array.items[i + 1]) ?? 0)
                let width = try DotNetMath.toInt32(file.resolveNumber(array.items[i + 2]) ?? 0)
                if last >= first && last - first < UInt32(maxMappedCodes) {
                    var k: UInt32 = 0
                    while k <= last - first && postDecrement(&budget) > 0 {
                        if widths[first &+ k] == nil {
                            widths[first &+ k] = width
                        }

                        k += 1
                    }
                }

                i += 3
            } else {
                break
            }
        }

        return widths
    }

    /// Reads the bfchar and bfrange sections of a ToUnicode CMap (ISO 32000-1, 9.10.3).
    private static func readToUnicode(_ data: [UInt8], _ map: inout OrderedDictionary<UInt32, String>) {
        let lexer = PdfLexer(data)
        var budget = 2 * maxMappedCodes
        while budget > 0 {
            let token = lexer.next()
            if token.kind == .end {
                return
            }

            if token.isKeyword("beginbfchar") {
                while true {
                    let source = lexer.next()
                    if source.kind != .string {
                        break
                    }

                    let target = lexer.next()
                    if target.kind == .string && source.bytes!.count >= 1 && source.bytes!.count <= 4 {
                        map.tryAdd(code(source.bytes!), text(target.bytes!))
                    }
                }
            } else if token.isKeyword("beginbfrange") {
                while true {
                    let low = lexer.next()
                    if low.kind != .string {
                        break
                    }

                    let high = lexer.next()
                    let target = lexer.next()
                    let from = code(low.bytes!)
                    let to = high.kind == .string ? code(high.bytes!) : from
                    let valid = to >= from && to - from < UInt32(maxMappedCodes) && low.bytes!.count <= 4
                    if target.kind == .string {
                        let units = text(target.bytes!).units
                        var k: UInt32 = 0
                        while valid && !units.isEmpty && k <= to &- from && postDecrement(&budget) > 0 {
                            // C# adds a uint to the last char and keeps its low 16 bits; an unpaired
                            // surrogate that makes becomes U+FFFD in a Swift string.
                            var copy = units
                            copy[copy.count - 1] = UInt16(truncatingIfNeeded: UInt32(units[units.count - 1]) &+ k)
                            map.tryAdd(from &+ k, String(units: copy))
                            k += 1
                        }
                    } else if target.kind == .arrayStart {
                        var code = from
                        var item = lexer.next()
                        while item.kind != .arrayEnd && item.kind != .end {
                            if valid && item.kind == .string && code <= to {
                                map.tryAdd(code, text(item.bytes!))
                            }

                            code &+= 1
                            item = lexer.next()
                        }
                    }
                }
            }
        }
    }

    private static func code(_ bytes: [UInt8]) -> UInt32 {
        var code: UInt32 = 0
        for b in bytes {
            code = code << 8 | UInt32(b)
        }

        return code
    }

    private static func text(_ utf16: [UInt8]) -> String { Utf16BigEndian.string(utf16) }

    /// C#'s `value-- > 0`: the value before it is decreased.
    private static func postDecrement(_ value: inout Int) -> Int {
        defer {
            value -= 1
        }

        return value
    }
}
