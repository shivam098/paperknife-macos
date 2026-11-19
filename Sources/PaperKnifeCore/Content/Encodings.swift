import Foundation

/// Character encodings of simple fonts (ISO 32000-1, Annex D) and glyph names mapped to Unicode,
/// for fonts without a ToUnicode map. Covers WinAnsiEncoding fully, and the ASCII range of
/// StandardEncoding and MacRomanEncoding; glyph names also by the Adobe Glyph List.
enum Encodings {
    // WinAnsiEncoding glyph names for codes 32 to 255; empty where the code is unused.
    private static let winAnsi: [String] = [
        "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand", "quotesingle",
        "parenleft", "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "colon", "semicolon", "less", "equal", "greater", "question", "at",
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        "bracketleft", "backslash", "bracketright", "asciicircum", "underscore", "grave",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
        "braceleft", "bar", "braceright", "asciitilde", "",
        "Euro", "", "quotesinglbase", "florin", "quotedblbase", "ellipsis", "dagger", "daggerdbl",
        "circumflex", "perthousand", "Scaron", "guilsinglleft", "OE", "", "Zcaron", "",
        "", "quoteleft", "quoteright", "quotedblleft", "quotedblright", "bullet", "endash", "emdash",
        "tilde", "trademark", "scaron", "guilsinglright", "oe", "", "zcaron", "Ydieresis",
        "space", "exclamdown", "cent", "sterling", "currency", "yen", "brokenbar", "section",
        "dieresis", "copyright", "ordfeminine", "guillemotleft", "logicalnot", "hyphen", "registered", "macron",
        "degree", "plusminus", "twosuperior", "threesuperior", "acute", "mu", "paragraph", "periodcentered",
        "cedilla", "onesuperior", "ordmasculine", "guillemotright", "onequarter", "onehalf", "threequarters", "questiondown",
        "Agrave", "Aacute", "Acircumflex", "Atilde", "Adieresis", "Aring", "AE", "Ccedilla",
        "Egrave", "Eacute", "Ecircumflex", "Edieresis", "Igrave", "Iacute", "Icircumflex", "Idieresis",
        "Eth", "Ntilde", "Ograve", "Oacute", "Ocircumflex", "Otilde", "Odieresis", "multiply",
        "Oslash", "Ugrave", "Uacute", "Ucircumflex", "Udieresis", "Yacute", "Thorn", "germandbls",
        "agrave", "aacute", "acircumflex", "atilde", "adieresis", "aring", "ae", "ccedilla",
        "egrave", "eacute", "ecircumflex", "edieresis", "igrave", "iacute", "icircumflex", "idieresis",
        "eth", "ntilde", "ograve", "oacute", "ocircumflex", "otilde", "odieresis", "divide",
        "oslash", "ugrave", "uacute", "ucircumflex", "udieresis", "yacute", "thorn", "ydieresis",
    ]

    // Windows-1252 characters for codes 128 to 159, which differ from Latin-1.
    private static let cp1252High: [UInt16] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    // StandardEncoding glyph names for codes above the ASCII range.
    private static let standardHigh: [Int: String] = [
        0xA1: "exclamdown", 0xA2: "cent", 0xA3: "sterling", 0xA4: "fraction", 0xA5: "yen", 0xA6: "florin",
        0xA7: "section", 0xA8: "currency", 0xA9: "quotesingle", 0xAA: "quotedblleft", 0xAB: "guillemotleft",
        0xAC: "guilsinglleft", 0xAD: "guilsinglright", 0xAE: "fi", 0xAF: "fl", 0xB1: "endash", 0xB2: "dagger",
        0xB3: "daggerdbl", 0xB4: "periodcentered", 0xB6: "paragraph", 0xB7: "bullet", 0xB8: "quotesinglbase",
        0xB9: "quotedblbase", 0xBA: "quotedblright", 0xBB: "guillemotright", 0xBC: "ellipsis", 0xBD: "perthousand",
        0xBF: "questiondown", 0xC1: "grave", 0xC2: "acute", 0xC3: "circumflex", 0xC4: "tilde", 0xC5: "macron",
        0xC6: "breve", 0xC7: "dotaccent", 0xC8: "dieresis", 0xCA: "ring", 0xCB: "cedilla", 0xCD: "hungarumlaut",
        0xCE: "ogonek", 0xCF: "caron", 0xD0: "emdash", 0xE1: "AE", 0xE3: "ordfeminine", 0xE8: "Lslash",
        0xE9: "Oslash", 0xEA: "OE", 0xEB: "ordmasculine", 0xF1: "ae", 0xF5: "dotlessi", 0xF8: "lslash",
        0xF9: "oslash", 0xFA: "oe", 0xFB: "germandbls",
    ]

    private static let lock = NSLock()
    private static var configuredGlyphList: URL?
    private static var builtGlyphUnicode: [String: String]?

    /// The Adobe Glyph List (third_party/agl): by default glyphlist.txt in the app bundle's fonts
    /// folder. Setting it reads the list again when it is next needed.
    static var glyphListURL: URL {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configuredGlyphList ?? BundledFonts.bundleRoot.appendingPathComponent("glyphlist.txt")
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            configuredGlyphList = newValue
            builtGlyphUnicode = nil
        }
    }

    private static var glyphUnicode: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let built = builtGlyphUnicode {
            return built
        }

        let built = buildGlyphUnicode(configuredGlyphList ?? BundledFonts.bundleRoot.appendingPathComponent("glyphlist.txt"))
        builtGlyphUnicode = built
        return built
    }

    static func winAnsiName(_ code: Int) -> String? {
        code >= 32 && code <= 255 && !winAnsi[code - 32].isEmpty ? winAnsi[code - 32] : nil
    }

    /// StandardEncoding, for the ASCII range only.
    static func standardName(_ code: Int) -> String? {
        switch code {
        case 39: return "quoteright"
        case 96: return "quoteleft"
        case 32...126: return winAnsiName(code)
        default: return nil
        }
    }

    /// StandardEncoding for every code (ISO 32000-1, D.2), for font programs that say they use it.
    static func fullStandardName(_ code: Int) -> String? { code <= 126 ? standardName(code) : standardHigh[code] }

    /// MacRomanEncoding, for the ASCII range only.
    static func macRomanName(_ code: Int) -> String? { code >= 32 && code <= 126 ? winAnsiName(code) : nil }

    /// Text with the Latin ligatures U+FB00 to U+FB06 replaced by their letters, the way PDFium's
    /// text extraction reports them (cpdf_textpage.cpp, AddCharInfo).
    static func expandLigatures(_ text: String) -> String {
        if !text.utf16.contains(where: { $0 >= 0xFB00 && $0 <= 0xFB06 }) {
            return text
        }

        var units: [UInt16] = []
        units.reserveCapacity(text.length + 4)
        for c in text.utf16 {
            switch c {
            case 0xFB00: units += [0x66, 0x66]
            case 0xFB01: units += [0x66, 0x69]
            case 0xFB02: units += [0x66, 0x6C]
            case 0xFB03: units += [0x66, 0x66, 0x69]
            case 0xFB04: units += [0x66, 0x66, 0x6C]
            case 0xFB05: units += [0x017F, 0x74]
            case 0xFB06: units += [0x73, 0x74]
            default: units.append(c)
            }
        }

        return String(units: units)
    }

    /// The text a glyph name stands for (Adobe Glyph List conventions), or nil.
    static func glyphToUnicode(_ name: String) -> String? {
        glyphToUnicodeUnits(name).map { String(units: $0) }
    }

    /// `glyphToUnicode` in UTF-16 code units, which C# joins as chars: the halves of a surrogate pair
    /// named apart ("uniD835_uniDC00") make one character. A half left alone becomes U+FFFD, as
    /// Swift strings can't hold one, as C#'s can.
    private static func glyphToUnicodeUnits(_ name: String) -> [UInt16]? {
        var name = name
        if let dot = name.ordinalIndexOf("."), dot > 0 {
            name = name.substring(0, dot)
        }

        if name.utf16.contains(0x5F) {
            let parts = name.split(onUnit: 0x5F).map(glyphToUnicodeUnits)
            return parts.allSatisfy({ $0 != nil }) ? parts.flatMap { $0! } : nil
        }

        if let known = glyphUnicode[name] {
            return known.units
        }

        let units = name.units
        if units.count == 7 && name.ordinalHasPrefix("uni"), let bmp = DotNetParse.hexInt32(units[3...]) {
            return [UInt16(truncatingIfNeeded: bmp)]
        }

        if units.count >= 5 && units.count <= 7 && units[0] == 0x75, let scalar = DotNetParse.hexInt32(units[1...]),
            scalar <= 0x10FFFF && (scalar < 0xD800 || scalar > 0xDFFF) {
            return DotNetChar.convertFromUtf32(scalar)?.units
        }

        return nil
    }

    private static func buildGlyphUnicode(_ glyphList: URL) -> [String: String] {
        var map: [String: String] = [:]
        func tryAdd(_ name: String, _ text: String) {
            if map[name] == nil {
                map[name] = text
            }
        }

        for code in 32...255 {
            if let name = winAnsiName(code) {
                let c = code >= 128 && code <= 159 ? cp1252High[code - 128] : UInt16(code)
                tryAdd(name, String(units: [c]))
            }
        }

        let more: [(String, String)] = [
            ("quoteright", "\u{2019}"), ("quoteleft", "\u{2018}"), ("nbspace", "\u{00A0}"), ("sfthyphen", "\u{00AD}"),
            ("minus", "\u{2212}"), ("dotlessi", "\u{0131}"), ("Lslash", "\u{0141}"), ("lslash", "\u{0142}"),
            ("fi", "\u{FB01}"), ("fl", "\u{FB02}"), ("ff", "\u{FB00}"), ("ffi", "\u{FB03}"), ("ffl", "\u{FB04}"),
            ("fraction", "\u{2044}"), ("ring", "\u{02DA}"), ("ogonek", "\u{02DB}"), ("caron", "\u{02C7}"),
            ("dotaccent", "\u{02D9}"), ("hungarumlaut", "\u{02DD}"), ("breve", "\u{02D8}"), ("Delta", "\u{2206}"),
            ("Omega", "\u{2126}"), ("pi", "\u{03C0}"), ("mu", "\u{00B5}"), ("rupee", "\u{20B9}"), ("uni20B9", "\u{20B9}"),
            ("Gamma", "\u{0393}"), ("Theta", "\u{0398}"), ("Lambda", "\u{039B}"), ("Xi", "\u{039E}"), ("Pi", "\u{03A0}"),
            ("Sigma", "\u{03A3}"), ("Upsilon", "\u{03A5}"), ("Phi", "\u{03A6}"), ("Psi", "\u{03A8}"),
        ]
        for (name, text) in more {
            tryAdd(name, text)
        }

        // Every other name the Adobe Glyph List has, as FreeType reads them for PDFium.
        for (name, text) in adobeGlyphList(glyphList) {
            tryAdd(name, text)
        }

        return map
    }

    /// The names in the Adobe Glyph List and the text each stands for; none when it can't be read.
    private static func adobeGlyphList(_ url: URL) -> [(name: String, text: String)] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        var entries: [(name: String, text: String)] = []
        for line in asciiLines(Array(data)) {
            let separator = line.ordinalIndexOf(";") ?? -1
            if line.ordinalHasPrefix("#") || separator <= 0 {
                continue
            }

            // One or more scalar values, in hexadecimal, separated by spaces.
            var text: [UInt16] = []
            for part in line.substring(separator + 1).split(onUnit: 0x20) {
                let value = part.dotNetTrim()
                if value.isEmpty {
                    continue
                }

                guard let scalar = DotNetParse.hexInt32(value.units), scalar <= 0x10FFFF, scalar < 0xD800 || scalar > 0xDFFF,
                    let character = DotNetChar.convertFromUtf32(scalar) else {
                    text.removeAll()
                    break
                }

                text += character.units
            }

            if !text.isEmpty {
                entries.append((line.substring(0, separator), String(units: text)))
            }
        }

        return entries
    }

    /// The lines of ASCII text as .NET's StreamReader.ReadLine reads them: ended by CR, LF or CR LF,
    /// with bytes past 0x7F read as "?".
    private static func asciiLines(_ bytes: [UInt8]) -> [String] {
        var lines: [String] = []
        var line: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            if b == 13 || b == 10 {
                lines.append(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
                if b == 13 && i < bytes.count && bytes[i] == 10 {
                    i += 1
                }
            } else {
                line.append(b > 0x7F ? 0x3F : b)
            }
        }

        if !line.isEmpty {
            lines.append(String(decoding: line, as: UTF8.self))
        }

        return lines
    }
}
