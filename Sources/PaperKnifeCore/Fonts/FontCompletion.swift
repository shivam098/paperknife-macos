/// A complete copy of a subset font, for new text that needs letters the subset lacks. TeX embeds
/// only the glyphs a document uses. When PaperKnife ships the font the subset was made from (see
/// `BundledFonts`), the edited text is drawn with a copy of the PDF's font that embeds the whole,
/// unmodified font program, added to the edited page as a font of its own. The PDF's own font, and
/// everything drawn with it on any page, stays exactly as it was.
///
/// The copy keeps the font's character map and the glyph of every code its /Differences name or
/// the page's text draws with it; the subset must be identical to PaperKnife's font for every
/// glyph it has (see `Type1Font.differenceFrom`), so the letters an edit keeps look and read the
/// same. Other codes select the glyph the character map says they stand for (see `glyphNames`),
/// and codes take the PDF's widths only where the PDF says they are those glyphs' (see
/// `copyWidths`). Only symbolic fonts whose codes select glyphs through the program's own
/// encoding (and /Differences) qualify, as TeX's fonts do: there, PDFium and the PDF specification
/// agree on which glyph each code draws.
final class FontCompletion {
    private static let symbolic = 4
    private static let nonsymbolic = 32
    private static let allCap = 1 << 16
    private static let maxNameAttempts = 32

    private let page: ContentPage
    private let glyphNames: OrderedDictionary<Int, String>

    // The codes whose glyph is the PDF's own, which stand for what its character map says.
    private let trusted: Set<Int>
    private let fontEntries: OrderedDictionary<String, CosObject>
    private let descriptorEntries: OrderedDictionary<String, CosObject>
    private let programNumber: Int
    private let descriptorNumber: Int
    private let fontNumber: Int

    private init(
        _ page: ContentPage,
        _ full: Type1Font,
        _ resourceName: String,
        _ info: PdfFontInfo,
        reused: Bool,
        _ glyphNames: OrderedDictionary<Int, String>,
        _ trusted: Set<Int>,
        _ fontEntries: OrderedDictionary<String, CosObject>,
        _ descriptorEntries: OrderedDictionary<String, CosObject>,
        _ firstNumber: Int
    ) {
        self.page = page
        self.full = full
        self.resourceName = resourceName
        self.info = info
        self.reused = reused
        self.glyphNames = glyphNames
        self.trusted = trusted
        self.fontEntries = fontEntries
        self.descriptorEntries = descriptorEntries
        programNumber = firstNumber
        descriptorNumber = firstNumber + 1
        fontNumber = firstNumber + 2
    }

    /// The font's name without its subset tag, for example "CMBX10".
    var fontName: String { full.fontName }

    let full: Type1Font

    /// The name of the copy in the page's font resources, which the edited text selects.
    let resourceName: String

    /// The copy's character codes and widths.
    let info: PdfFontInfo

    /// Whether the page already has such a copy, from an earlier edit, so nothing needs to be added.
    let reused: Bool

    /// A complete copy of the font the page's resource `resourceName` names, or nil when PaperKnife
    /// can't make one. `difference` says why when PaperKnife ships a font of that name but can't use it.
    static func tryCreate(_ page: ContentPage, _ resourceName: String, _ difference: inout String?) throws -> FontCompletion? {
        difference = nil
        let file = page.file
        let fonts = try file.resolveDict(page.page.resources?["Font"])
        guard let fonts, let entry = fonts[resourceName], let font = try file.resolveDict(entry),
            let qualified = try qualify(file, font, &difference) else {
            return nil
        }

        let (full, descriptor, flags) = qualified
        guard let embedded = try readProgram(file, descriptor) else {
            difference = "it couldn't read the font in this PDF"
            return nil
        }

        if let reason = embedded.differenceFrom(full) {
            difference = "in this PDF \(reason)"
            return nil
        }

        let differences = try Self.differences(file, font)
        let toUnicode = try PdfFontInfo.toUnicode(file, font["ToUnicode"])
        let drawn = codesDrawn(page, resourceName)
        let glyphNames = Self.glyphNames(full, differences, toUnicode, drawn)

        // The codes whose glyph is the PDF's own: those its /Differences name and those the page draws,
        // or, when it has no /Differences, every code the copy doesn't give another glyph.
        let trusted = !differences.isEmpty
            ? drawn.union(differences.keys)
            : Set((0..<256).filter { glyphNames[$0] == builtin(full, $0) })
        guard let widths = try copyWidths(file, font, full, embedded, glyphNames, differences, toUnicode) else {
            return nil
        }

        let encoding = copyEncoding(font, full, differences, glyphNames)

        // A copy an earlier edit added to this page serves as well, if it is exactly what this one would be.
        var programs: [Int: Bool] = [:]
        for (name, value) in fonts.entries where name != resourceName {
            if let other = try file.resolveDict(value), try isSameCopy(file, other, font, encoding, flags, full, widths, &programs) {
                let otherInfo = try PdfFontInfo.load(file, other, { builtin(full, $0) })
                return FontCompletion(
                    page, full, name, otherInfo, reused: true, glyphNames, trusted, OrderedDictionary(), OrderedDictionary(), 0)
            }
        }

        // The copy takes the next three object numbers, which must stay within those PDFium reads.
        if file.size > PdfFile.maxObjectNumber - 2 {
            difference = "the PDF has too many objects to add it"
            return nil
        }

        guard let resource = freeName(page, fonts, "PK\(full.fontName)") else {
            return nil
        }

        let number = file.size
        let baseFont = "\(tag((entry as? CosRef)?.number ?? 0))+\(full.fontName)"
        var descriptorEntries = OrderedDictionary(descriptor.entries.map { ($0.key, $0.value) })
        descriptorEntries["FontName"] = CosName(baseFont)
        descriptorEntries["FontFile"] = CosRef(number, 0)
        descriptorEntries.removeValue(forKey: "CharSet")

        var fontEntries = OrderedDictionary<String, CosObject>()
        fontEntries["Type"] = CosName("Font")
        fontEntries["Subtype"] = CosName("Type1")
        fontEntries["BaseFont"] = CosName(baseFont)
        fontEntries["FirstChar"] = integer(widths.first)
        fontEntries["LastChar"] = integer(widths.first + widths.values.count - 1)
        fontEntries["Widths"] = CosArray(widths.values)
        if let encoding {
            fontEntries["Encoding"] = encoding
        }

        if let map = font["ToUnicode"] {
            fontEntries["ToUnicode"] = map
        }

        // The copy as PdfFontInfo reads it, with its descriptor inline: the new objects don't exist yet.
        var readable = OrderedDictionary(fontEntries.map { ($0.key, $0.value) })
        readable["FontDescriptor"] = CosDict(descriptorEntries)
        fontEntries["FontDescriptor"] = CosRef(number + 1, 0)
        let info = try PdfFontInfo.load(file, CosDict(readable), { builtin(full, $0) })
        return FontCompletion(page, full, resource, info, reused: false, glyphNames, trusted, fontEntries, descriptorEntries, number)
    }

    /// Whether the copy draws the glyph for `text` for `code`. A glyph that is the PDF's own (one it
    /// names or the page draws, or any it didn't remap in a font without /Differences) stands for
    /// what the PDF's character map says; any other is judged by its name.
    func draws(_ code: UInt32, _ text: String) -> Bool {
        let index = Int(Int32(bitPattern: code))
        guard let name = glyphNames[index], full.charStrings.contains(key: name) else {
            return false
        }

        return trusted.contains(index) || Self.standsFor(name, text)
    }

    /// Whether the font the page's resource `resourceName` names selects its glyphs by name in a way
    /// PaperKnife reads exactly: a symbolic Type 1 font, embedded as a Type 1 program, whose codes
    /// select glyphs through the program's own encoding and /Differences, as pdfTeX's fonts do. Its
    /// glyph names then say which glyph each code draws, in PDFium as in PaperKnife, whether or not
    /// PaperKnife ships the font.
    static func selectsGlyphsByName(_ page: ContentPage, _ resourceName: String) throws -> Bool {
        let file = page.file
        guard let font = try file.resolveDict(file.resolveDict(page.page.resources?["Font"])?[resourceName]),
            try file.resolveName(font["Subtype"]) == "Type1", let described = try describes(file, font) else {
            return false
        }

        let descriptor = described.0
        return descriptor["FontFile"] != nil && descriptor["FontFile2"] == nil && descriptor["FontFile3"] == nil
    }

    /// Whether a glyph name stands for `text` (see `comparable`).
    private static func standsFor(_ name: String, _ text: String) -> Bool {
        guard let unicode = Encodings.glyphToUnicode(name) else {
            return false
        }

        return comparable(unicode).ordinalEquals(comparable(text))
    }

    /// The objects to append: the font program, the copy's descriptor and font dictionary, and a new
    /// version of the page that lists the copy among its fonts. Nothing when the copy exists.
    func updates() throws -> [ObjectUpdate] {
        if reused {
            return []
        }

        let file = page.file
        let pageNode = page.page
        guard let pageResources = pageNode.resources, let pageFonts = try file.resolveDict(pageResources["Font"]) else {
            throw DotNetThrows.nullReference()
        }

        var fonts = OrderedDictionary(pageFonts.entries.map { ($0.key, $0.value) })
        fonts[resourceName] = CosRef(fontNumber, 0)

        // The page gets resources of its own, so pages that share or inherit them don't change.
        var resources = OrderedDictionary(pageResources.entries.map { ($0.key, $0.value) })
        resources["Font"] = CosDict(fonts)
        var pageEntries = OrderedDictionary(pageNode.dict.entries.map { ($0.key, $0.value) })
        pageEntries["Resources"] = CosDict(resources)
        var lengths = OrderedDictionary<String, CosObject>()
        lengths["Length1"] = Self.integer(full.length1)
        lengths["Length2"] = Self.integer(full.length2)
        lengths["Length3"] = Self.integer(full.length3)
        return [
            StreamUpdate(programNumber, 0, full.program, lengths),
            ValueUpdate(descriptorNumber, 0, CosDict(descriptorEntries)),
            ValueUpdate(fontNumber, 0, CosDict(fontEntries)),
            ValueUpdate(pageNode.number, pageNode.generation, CosDict(pageEntries)),
        ]
    }

    /// Whether the font has no /Encoding, or one that only lists /Differences, so its program's encoding is the base.
    private static func hasProgramEncoding(_ file: PdfFile, _ font: CosDict) throws -> Bool {
        if font["Encoding"] == nil {
            return true
        }

        guard let encoding = try file.resolve(font["Encoding"]) as? CosDict else {
            return false
        }

        return encoding.entries.keys.allSatisfy { $0 == "Type" || $0 == "Differences" }
    }

    private static func readProgram(_ file: PdfFile, _ descriptor: CosDict) throws -> Type1Font? {
        guard descriptor["FontFile2"] == nil, descriptor["FontFile3"] == nil,
            let stream = try file.resolve(descriptor["FontFile"]) as? CosStream,
            let length1 = try file.resolveNumber(stream.dict["Length1"]), length1 >= 1 && length1 <= Double(Type1Font.maxProgram),
            let length2 = try file.resolveNumber(stream.dict["Length2"]), length2 >= 1 && length2 <= Double(Type1Font.maxProgram),
            let data = try file.decodeStream(stream, limit: Type1Font.maxProgram) else {
            return nil
        }

        return Type1Font.fromEmbedded(data, DotNetMath.toInt32(length1), DotNetMath.toInt32(length2))
    }

    /// The glyph names the font's /Differences give codes, in order, as PDFium reads them.
    private static func differences(_ file: PdfFile, _ font: CosDict) throws -> OrderedDictionary<Int, String> {
        var names = OrderedDictionary<Int, String>()
        var next = 0
        for item in try file.resolveArray(file.resolveDict(font["Encoding"])?["Differences"])?.items ?? [] {
            let value = try file.resolve(item)
            if let number = value as? CosNumber {
                next = DotNetMath.toInt32(number.value)
            } else if let name = value as? CosName, next >= 0 && next < 256 {
                names[next] = name.value
                next += 1
            }
        }

        return names
    }

    /// The glyph each code of the copy selects. Every code the page's text draws with the font, and
    /// every code its /Differences name, keeps its glyph: the copy is only for this page, and the
    /// letters an edit keeps are drawn with it, with the codes they had. pdfTeX names only the codes
    /// a document uses, though its character map (and its widths) follow TeX's encoding for every
    /// code; at the others the full program draws the glyphs of its own encoding, which differs.
    /// So when the character map says such a code stands for a character the program's glyph
    /// isn't, the copy selects the program's glyph for exactly that character, if there is one.
    /// - Parameter drawn: The codes the page's text draws with the font.
    private static func glyphNames(
        _ full: Type1Font, _ differences: OrderedDictionary<Int, String>, _ toUnicode: OrderedDictionary<UInt32, String>?, _ drawn: Set<Int>
    ) -> OrderedDictionary<Int, String> {
        var names = OrderedDictionary<Int, String>()
        var byText: [OrdinalString: String]?
        for code in 0..<256 {
            var name = differences[code] ?? builtin(full, code)
            if !differences.contains(key: code) && !drawn.contains(code), let text = toUnicode?[UInt32(code)], !text.isEmpty,
                !(name.map { full.charStrings.contains(key: $0) && standsFor($0, text) } ?? false) {
                if byText == nil {
                    byText = glyphsByText(full)
                }

                if let glyph = byText?[OrdinalString(text.normalizedFormC)] {
                    name = glyph
                }
            }

            if let name {
                names[code] = name
            }
        }

        return names
    }

    /// The codes the page's text draws with the font a resource names, under that name or any
    /// other the page gives the same font.
    private static func codesDrawn(_ page: ContentPage, _ resourceName: String) -> Set<Int> {
        let font = page.text.shows.first(where: { $0.fontName == resourceName })?.font
        var codes = Set<Int>()
        for show in page.text.shows where show.font != nil && (show.fontName == resourceName || show.font === font) {
            for (code, _) in show.codes() {
                codes.insert(Int(Int32(bitPattern: code)))
            }
        }

        return codes
    }

    /// The full program, descriptor and flags of a font PaperKnife may make a copy of: a Type 1 font
    /// it ships, symbolic, whose /Encoding is absent or lists only /Differences. Nil otherwise;
    /// `difference` then says why when PaperKnife ships a font of that name.
    private static func qualify(_ file: PdfFile, _ font: CosDict, _ difference: inout String?) throws -> (Type1Font, CosDict, Int)? {
        difference = nil
        guard try file.resolveName(font["Subtype"]) == "Type1",
            let full = try BundledFonts.findType1(Type1Font.baseName(file.resolveName(font["BaseFont"]) ?? "")) else {
            return nil
        }

        guard let described = try describes(file, font) else {
            difference = "the PDF describes the font in a way PaperKnife can't add letters to yet"
            return nil
        }

        return (full, described.0, described.1)
    }

    /// The descriptor and flags of a symbolic font whose /Encoding is absent or lists only
    /// /Differences, so that its codes select glyphs through its program's own encoding. Nil for
    /// any other font.
    private static func describes(_ file: PdfFile, _ font: CosDict) throws -> (CosDict, Int)? {
        let descriptor = try file.resolveDict(font["FontDescriptor"])
        let flags = DotNetMath.toInt32(try file.resolveNumber(descriptor?["Flags"]) ?? 0)
        guard let descriptor, flags & symbolic != 0, flags & (nonsymbolic | allCap) == 0, try hasProgramEncoding(file, font) else {
            return nil
        }

        return (descriptor, flags)
    }

    /// The full program's glyphs by the exact text they stand for: a look-alike, such as ε for ϵ,
    /// won't do. Variants (names with a suffix, such as "a.sc") are left out: a character map can't
    /// ask for them. The first name in ordinal order wins, so the copy is the same every time.
    private static func glyphsByText(_ full: Type1Font) -> [OrdinalString: String] {
        var glyphs: [OrdinalString: String] = [:]
        let names = full.charStrings.keys.filter { !$0.utf16.contains(0x2E) }.stableSorted(by: String.ordinalLess)
        for name in names {
            if let text = Encodings.glyphToUnicode(name), !text.isEmpty {
                let key = OrdinalString(text.normalizedFormC)
                if glyphs[key] == nil {
                    glyphs[key] = name
                }
            }
        }

        return glyphs
    }

    /// The copy's /Encoding: the font's own when the copy selects the same glyphs as it would, or
    /// else its /Differences with the codes `glyphNames` gave other glyphs.
    private static func copyEncoding(
        _ font: CosDict, _ full: Type1Font, _ differences: OrderedDictionary<Int, String>, _ names: OrderedDictionary<Int, String>
    ) -> CosObject? {
        let added = names.filter { !differences.contains(key: $0.key) && $0.value != builtin(full, $0.key) }
        if added.isEmpty {
            return font["Encoding"]
        }

        var items: [CosObject] = []
        var previous = -2
        let all = differences.map { (key: $0.key, value: $0.value) } + added.map { (key: $0.key, value: $0.value) }
        for (code, name) in all.stableSorted(by: { $0.key < $1.key }) {
            if code != previous + 1 {
                items.append(integer(code))
            }

            items.append(CosName(name))
            previous = code
        }

        var entries = OrderedDictionary<String, CosObject>()
        entries["Type"] = CosName("Encoding")
        entries["Differences"] = CosArray(items)
        return CosDict(entries)
    }

    /// The copy's /Widths. A code keeps the font's width when the PDF says it is that of the glyph
    /// the copy selects: /Differences names the glyph, or the font has none, so its codes select
    /// its program's glyphs; or the character map says the code stands for the glyph's character,
    /// as pdfTeX gives every code the width of TeX's glyph for it. Other codes take the glyph's
    /// width in the full program, so new letters advance as the font intends: some tools give the
    /// glyphs they leave out of a subset a width of 0, and pdfTeX's widths may be for another glyph.
    private static func copyWidths(
        _ file: PdfFile,
        _ font: CosDict,
        _ full: Type1Font,
        _ embedded: Type1Font,
        _ glyphNames: OrderedDictionary<Int, String>,
        _ differences: OrderedDictionary<Int, String>,
        _ toUnicode: OrderedDictionary<UInt32, String>?
    ) throws -> (first: Int, values: [CosNumber])? {
        guard let array = try file.resolveArray(font["Widths"]), array.count > 0, let firstChar = try file.resolveNumber(font["FirstChar"]),
            firstChar >= 0 && firstChar <= 255 else {
            return nil
        }

        // The codes /Widths covers, as PdfFontInfo and PDFium read them.
        let first = DotNetMath.toInt32(firstChar)
        let lastChar = DotNetMath.toInt32(try file.resolveNumber(font["LastChar"]) ?? 0)
        let last = min(255, lastChar == 0 || lastChar >= first + array.count ? first + array.count - 1 : lastChar)
        let drawn = glyphNames.filter { full.charStrings.contains(key: $0.value) }.map(\.key)
        let low = drawn.isEmpty ? first : min(first, drawn.min()!)
        let high = drawn.isEmpty ? last : max(last, drawn.max()!)
        var values: [CosNumber] = []
        var code = low
        while code <= high {
            let name = glyphNames[code]
            var own: CosNumber?
            if code >= first && code <= last {
                own = try file.resolve(array[code - first]) as? CosNumber ?? integer(0)
            }

            let keep: Bool
            if let own {
                if differences.isEmpty || differences.contains(key: code) {
                    // A glyph the subset has keeps its width, even 0: the PDF's text is drawn with it.
                    keep = DotNetMath.toInt32(own.value) > 0 || name == nil || embedded.charStrings.contains(key: name!)
                } else {
                    keep = DotNetMath.toInt32(own.value) > 0 && name != nil && toUnicode?[UInt32(code)].map { standsFor(name!, $0) } == true
                }
            } else {
                keep = false
            }

            if keep, let own {
                values.append(own)
            } else {
                let width = name.flatMap { full.width($0) }
                values.append(integer(width.map { $0.isFinite ? DotNetMath.toInt32(DotNetMath.round($0)) : 0 } ?? 0))
            }

            code += 1
        }

        return (low, values)
    }

    /// Whether a font of the page is exactly the copy this completion would add: the same full
    /// program, encoding, character map and flags, and the same widths for every code the copy covers.
    /// - Parameters:
    ///   - encoding: The copy's /Encoding (see `copyEncoding`).
    ///   - programs: Font programs already compared with the full one, by object number.
    private static func isSameCopy(
        _ file: PdfFile,
        _ other: CosDict,
        _ font: CosDict,
        _ encoding: CosObject?,
        _ flags: Int,
        _ full: Type1Font,
        _ widths: (first: Int, values: [CosNumber]),
        _ programs: inout [Int: Bool]
    ) throws -> Bool {
        let descriptor = try file.resolveDict(other["FontDescriptor"])
        guard try file.resolveName(other["Subtype"]) == "Type1",
            try Type1Font.baseName(file.resolveName(other["BaseFont"]) ?? "") == full.fontName,
            let descriptor, try DotNetMath.toInt32(file.resolveNumber(descriptor["Flags"]) ?? 0) == flags,
            try sameEntry(file, other["Encoding"], encoding), try sameEntry(file, other["ToUnicode"], font["ToUnicode"]),
            descriptor["FontFile2"] == nil, descriptor["FontFile3"] == nil,
            try isFullProgram(file, descriptor["FontFile"], full, &programs) else {
            return false
        }

        let theirs = try readWidths(file, other)
        for i in 0..<widths.values.count {
            guard let width = theirs[widths.first + i], width == DotNetMath.toInt32(widths.values[i].value) else {
                return false
            }
        }

        return true
    }

    /// Whether an embedded program is exactly the full font's. Each stream is decoded once, and no
    /// further than the full program's length.
    private static func isFullProgram(_ file: PdfFile, _ entry: CosObject?, _ full: Type1Font, _ programs: inout [Int: Bool]) throws -> Bool {
        if let known = entry as? CosRef, let same = programs[known.number] {
            return same
        }

        var same = false
        if let stream = try file.resolve(entry) as? CosStream,
            try file.resolveNumber(stream.dict["Length1"]) == Double(full.length1),
            try file.resolveNumber(stream.dict["Length2"]) == Double(full.length2),
            let data = try file.decodeStream(stream, limit: full.program.count) {
            same = data == full.program
        }

        if let reference = entry as? CosRef {
            programs[reference.number] = same
        }

        return same
    }

    // Whole-number widths by code, as PDFium reads /Widths.
    private static func readWidths(_ file: PdfFile, _ font: CosDict) throws -> [Int: Int] {
        var widths: [Int: Int] = [:]
        if let array = try file.resolveArray(font["Widths"]), let first = try file.resolveNumber(font["FirstChar"]), first >= 0 && first <= 255 {
            let lastChar = DotNetMath.toInt32(try file.resolveNumber(font["LastChar"]) ?? 0)
            let start = DotNetMath.toInt32(first)
            let last = min(255, lastChar == 0 || Double(lastChar) >= first + Double(array.count) ? start + array.count - 1 : lastChar)
            var code = start
            while code <= last {
                // With a fractional /FirstChar this can index past the array, which throws as in C#.
                widths[code] = DotNetMath.toInt32(try file.resolveNumber(array[code - start]) ?? 0)
                code += 1
            }
        }

        return widths
    }

    // The same object, or the same value.
    private static func sameEntry(_ file: PdfFile, _ a: CosObject?, _ b: CosObject?) throws -> Bool {
        guard let a, let b else {
            return a == nil && b == nil
        }

        if let x = a as? CosRef, let y = b as? CosRef {
            return x.number == y.number && x.generation == y.generation
        }

        guard let first = try file.resolve(a), !(first is CosStream), let second = try file.resolve(b), !(second is CosStream) else {
            return false
        }

        return try CosWriter.toText(first).ordinalEquals(CosWriter.toText(second))
    }

    /// A name for the copy that neither the page's fonts nor its content use yet.
    private static func freeName(_ page: ContentPage, _ fonts: CosDict, _ stem: String) -> String? {
        var used = Set<String>()
        for op in page.ops {
            for case let name as CosName in op.operands {
                used.insert(name.value)
            }
        }

        for attempt in 0..<maxNameAttempts {
            let name = attempt == 0 ? stem : "\(stem)_\(attempt)"
            if fonts[name] == nil && !used.contains(name) {
                return name
            }
        }

        return nil
    }

    /// A subset tag for the copy, "PK" and four letters from the original font's object number.
    private static func tag(_ number: Int) -> String {
        var number = number
        var letters = [UInt16](repeating: 0, count: 4)
        for i in stride(from: 3, through: 0, by: -1) {
            letters[i] = UInt16(0x41 + abs(number) % 26)
            number /= 26
        }

        return "PK" + String(units: letters)
    }

    /// The glyph a font program's own encoding gives a code.
    private static func builtin(_ font: Type1Font, _ code: Int) -> String? {
        font.usesStandardEncoding ? Encodings.fullStandardName(code) : font.encoding[code]
    }

    private static func comparable(_ text: String) -> String { text.normalizedFormKC.ordinalReplacing("\u{A0}", with: " ") }

    private static func integer(_ value: Int) -> CosNumber { CosNumber(Double(value), String(value)) }
}
