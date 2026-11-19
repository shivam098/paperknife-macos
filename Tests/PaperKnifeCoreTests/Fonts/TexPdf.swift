@testable import PaperKnifeCore

/// Which bundled font `TexPdf` cuts its subset from and how, and the ways a crafted subset can differ.
struct TexSubset {
    /// The bundled font: CMR10 as pdfLaTeX embeds it by default, LMRoman10-Regular with lmodern, SFRM1000 with T1 encoding.
    var font = "CMR10"

    /// Describes the encoding with /Differences for the codes the subset uses, as pdfTeX does for
    /// Latin Modern and CM-Super, rather than leaving it to the font's own encoding, as for Computer Modern.
    var withDifferences = false

    /// The font's name in the PDF, when it isn't the bundled font's: as for a font PaperKnife doesn't ship.
    var rename: String?

    /// Codes the PDF gives glyphs where TeX's encoding differs from the font's own (in T1, ß is 255).
    var pdfCodes: [String: Int]?

    var glyphs = ["H", "d", "e", "l", "o", "r", "w"]

    /// The glyphs the font dictionary's /Differences and /Widths describe, when only some of the
    /// subset's: pdfTeX embeds one subset for the fonts that use a program in several encodings,
    /// such as the letters' and the symbols' (T1 and TS1).
    var described: [String]?

    /// A glyph whose program is replaced by "e"'s, so the subset no longer matches the full font.
    var replaceGlyph: String?

    /// A token among the glyph programs, before the last one. Renderers skip it.
    var strayToken = false

    /// The first glyph defined twice: first with "e"'s program, which renderers use, then with its own.
    var duplicateGlyph = false

    /// A glyph whose last subroutine becomes a stub that only returns, as subsetters do for unused ones.
    var stubSubroutineOf: String?

    /// Bytes of comments full of half-written keys in the private part (and a tenth in the cleartext).
    var junk = 0
}

/// PDFs set the way pdfTeX sets them (C#'s TexPdf). Only the subset fonts are ported so far: the
/// documents themselves come with the DocumentSession tests.
enum TexPdf {
    static var full: Type1Font { font("CMR10") }

    static func font(_ name: String) -> Type1Font {
        guard let font = BundledFonts.findType1(name) else {
            preconditionFailure("PaperKnife doesn't ship \(name).")
        }

        return font
    }

    /// The three parts of a subset of a bundled font, as Latin-1 bytes: only some glyphs, and
    /// .notdef, written with the font's own spelling of the charstring delimiters (RD and ND, or
    /// -| and |-), as subsetters keep them.
    static func subset(_ subset: TexSubset) -> (clear: [UInt8], encrypted: [UInt8], trailer: [UInt8]) {
        let full = font(subset.font)
        var clear = replacing(
            Array(full.program[0..<full.length1]), "/FontName /\(full.fontName)", "/FontName /AAAAAA+\(subset.rename ?? full.fontName)")
        let trailer = Array(full.program[(full.length1 + full.length2)..<(full.length1 + full.length2 + full.length3)])

        // The private part keeps its random first bytes, so it encrypts back to the same start.
        let plain = Type1Font.decrypt(full.program[full.length1..<(full.length1 + full.length2)], 55665, 0)
        let begin = indexOf(plain, "begin", indexOf(plain, "/CharStrings", 0)!)! + 5
        var entries: [String: [UInt8]] = [:]
        var rd = "RD"
        var nd = "ND"
        var position = begin
        while true {
            while DotNetChar.isWhiteSpace(UInt16(plain[position])) {
                position += 1
            }

            if plain[position] != UInt8(ascii: "/") {
                break
            }

            let (name, data, end, read) = entry(plain, position, 3)
            entries[name.substring(1)] = data
            rd = read
            (nd, position) = nextToken(plain, end)
        }

        var kept = Latin1.bytes("\n")
        let glyphs = subset.glyphs + [".notdef"]
        if subset.duplicateGlyph {
            kept += Latin1.bytes("/\(glyphs[0]) \(entries["e"]!.count) \(rd) ") + entries["e"]! + Latin1.bytes(" \(nd)\n")
        }

        for i in 0..<glyphs.count {
            if subset.strayToken && i == glyphs.count - 1 {
                kept += Latin1.bytes("0 pop\n")
            }

            let data = glyphs[i] == subset.replaceGlyph ? entries["e"]! : entries[glyphs[i]]!
            kept += Latin1.bytes("/\(glyphs[i]) \(data.count) \(rd) ") + data + Latin1.bytes(" \(nd)\n")
        }

        var result = Array(plain[0..<begin]) + kept + Array(plain[position...])
        if let glyph = subset.stubSubroutineOf {
            // "dup <index> <length> RD <data>" becomes a stub that only returns (after four random bytes).
            let index = CharStringAnalyzer.analyze(full.charStrings[glyph]!, full.subrs, CharStringAnalyzer.Budget(100_000))!.subrs.max()!
            let start = indexOf(result, "dup \(index) ", indexOf(result, "/Subrs", 0)!)!
            let (_, _, end, read) = entry(result, start + 4, 3)
            let stub = encrypt([0, 0, 0, 0, 11], 4330)
            result = Array(result[0..<start]) + Latin1.bytes("dup \(index) 5 \(read) ") + stub + Array(result[end...])
        }

        if subset.junk > 0 {
            let line = clear.firstIndex(of: 10)! + 1
            clear.insert(contentsOf: Latin1.bytes("%" + repeated("/FontMatrix[", subset.junk / 10) + "\n"), at: line)
            result.insert(contentsOf: Latin1.bytes("%" + repeated("/BlueValues[", subset.junk) + "\n"), at: indexOf(result, "/CharStrings", 0)!)
        }

        return (clear, encrypt(result, 55665), trailer)
    }

    // "<first> <length> <RD> <data>" at a position: the first token, the data, where the data ends and how RD is spelled.
    private static func entry(_ text: [UInt8], _ position: Int, _ tokens: Int) -> (first: String, data: [UInt8], end: Int, rd: String) {
        let window = text[position..<min(text.count, position + 80)]
        let parts = window.split(separator: UInt8(ascii: " "), maxSplits: tokens, omittingEmptySubsequences: false).map { Latin1.string($0) }
        let length = Int(parts[1])!
        let dataStart = position + parts.prefix(tokens).reduce(0) { $0 + $1.utf16.count + 1 }
        return (parts[0], Array(text[dataStart..<(dataStart + length)]), dataStart + length, parts[tokens - 1])
    }

    // The token after a position (such as ND after a glyph's data), and where it ends.
    private static func nextToken(_ text: [UInt8], _ position: Int) -> (token: String, end: Int) {
        var position = position
        while DotNetChar.isWhiteSpace(UInt16(text[position])) {
            position += 1
        }

        var end = position
        while end < text.count && !DotNetChar.isWhiteSpace(UInt16(text[end])) {
            end += 1
        }

        return (Latin1.string(text[position..<end]), end)
    }

    private static func repeated(_ text: String, _ bytes: Int) -> String {
        String(repeating: text, count: max(1, bytes / text.utf16.count))
    }

    private static func encrypt(_ plain: [UInt8], _ key: Int) -> [UInt8] {
        var cipher = [UInt8](repeating: 0, count: plain.count)
        var r = UInt32(key)
        for i in 0..<plain.count {
            let c = plain[i] ^ UInt8(truncatingIfNeeded: r >> 8)
            cipher[i] = c
            r = ((UInt32(c) &+ r) &* 52845 &+ 22719) & 0xFFFF
        }

        return cipher
    }

    /// C#'s ordinal IndexOf on Latin-1 text.
    private static func indexOf(_ text: [UInt8], _ value: String, _ start: Int) -> Int? {
        let needle = Latin1.bytes(value)
        var i = start
        while i + needle.count <= text.count {
            if text[i] == needle[0] && text[i..<(i + needle.count)].elementsEqual(needle) {
                return i
            }

            i += 1
        }

        return nil
    }

    /// C#'s ordinal Replace on Latin-1 text: every occurrence.
    private static func replacing(_ text: [UInt8], _ old: String, _ new: String) -> [UInt8] {
        let target = Latin1.bytes(old)
        let replacement = Latin1.bytes(new)
        var result: [UInt8] = []
        var i = 0
        while i < text.count {
            if i + target.count <= text.count && text[i..<(i + target.count)].elementsEqual(target) {
                result += replacement
                i += target.count
            } else {
                result.append(text[i])
                i += 1
            }
        }

        return result
    }
}
