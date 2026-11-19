/// A glyph to draw: its code, its advance for a font size of 1, and the TJ adjustment after it.
struct PlannedGlyph {
    var code: UInt32

    var width: Double

    var kerningAfter: Double

    init(_ code: UInt32, _ width: Double, _ kerningAfter: Double) {
        self.code = code
        self.width = width
        self.kerningAfter = kerningAfter
    }
}

/// A glyph of the text being replaced: its code, width and the TJ adjustment after it, the text
/// PDFium reads for it, and whether PDFium reads that adjustment as a space. `reusable` is false
/// when the glyph was drawn in a different text state than the edited object's, so its code and
/// adjustments can't be copied.
struct OldGlyph {
    let code: UInt32

    let width: Double

    let kerningAfter: Double

    let text: String

    let show: Int

    let spaceAfter: Bool

    let separatorBefore: Bool

    let reusable: Bool

    init(
        _ code: UInt32, _ width: Double, _ kerningAfter: Double, _ text: String, _ show: Int, _ spaceAfter: Bool,
        _ separatorBefore: Bool, _ reusable: Bool
    ) {
        self.code = code
        self.width = width
        self.kerningAfter = kerningAfter
        self.text = text
        self.show = show
        self.spaceAfter = spaceAfter
        self.separatorBefore = separatorBefore
        self.reusable = reusable
    }
}

/// How a text object's new text is drawn: its glyphs and the TJ adjustments around them.
final class GlyphPlan {
    init(
        initialKerning: Double, glyphs: [PlannedGlyph], trailingKerning: Double, visibleGlyphs: Int, missing: [String],
        newGlyphs: [(text: String, code: UInt32)]
    ) {
        self.initialKerning = initialKerning
        self.glyphs = glyphs
        self.trailingKerning = trailingKerning
        self.visibleGlyphs = visibleGlyphs
        self.missing = missing
        self.newGlyphs = newGlyphs
    }

    /// The TJ adjustment before the first glyph, in thousandths of an em (negative moves right).
    let initialKerning: Double

    let glyphs: [PlannedGlyph]

    /// The gap that spaces after the last glyph (or spaces alone) leave, as a TJ adjustment.
    let trailingKerning: Double

    /// The number of glyphs up to the last character that isn't a space.
    let visibleGlyphs: Int

    /// Characters the font has no code for.
    let missing: [String]

    /// The characters drawn with codes chosen for them rather than kept from the old text, whose glyphs must be checked.
    let newGlyphs: [(text: String, code: UInt32)]

    var newCharacters: String { String(units: newGlyphs.flatMap { Array($0.text.utf16) }) }

    var hasAdjustments: Bool { initialKerning != 0 || glyphs.contains { $0.kerningAfter != 0 } }
}

/// Chooses the glyphs that draw a text object's new text. Text kept from the old object keeps its
/// codes, its kerning and the gaps PDFium reads as spaces, so an edit changes only what changed.
/// Spaces the font can't draw become gaps, the way TeX sets every space: TeX fonts have no space
/// glyph, so without this no text with a space could be written in them.
final class GlyphPlanner {
    private static let maxAlignmentCells = 4_000_000

    init(
        font: PdfFontInfo, width: @escaping (UInt32) -> Double?, preferred: Set<UInt32>, spaceCode: UInt32?,
        wordGap: @escaping () throws -> Double, old: [OldGlyph]?
    ) {
        self.font = font
        self.width = width
        self.preferred = preferred
        self.spaceCode = spaceCode
        self.wordGap = wordGap
        self.old = old
    }

    let font: PdfFontInfo

    /// The advance of a code for a font size of 1, as PDFium computes it.
    let width: (UInt32) -> Double?

    /// Codes to prefer when a character has several, normally the ones the old text used.
    let preferred: Set<UInt32>

    /// A code that draws a space, or nil when spaces have to be gaps.
    let spaceCode: UInt32?

    /// The usual gap between words in this font, in thousandths of an em.
    let wordGap: () throws -> Double

    /// The glyphs being replaced, or nil when they can't be matched to the text PDFium reads.
    let old: [OldGlyph]?

    func plan(_ newText: String) throws -> GlyphPlan {
        let old = self.old ?? []
        let oldChars = Self.oldCharacters(old)
        let aligned = try Self.align(oldChars, newText)
        let units = newText.units
        var glyphs: [PlannedGlyph] = []
        var sources: [Int] = []
        var pending: [Int] = []
        var missing: [String] = []
        var fresh: [(text: String, code: UInt32)] = []
        var initial: Double = 0
        var visible = 0
        var j = 0

        func add(_ code: UInt32, _ width: Double, _ from: Int) throws {
            if glyphs.isEmpty {
                initial = try pending.count > 0 ? -sumOfGaps(pending) : 0
            } else {
                let previous = sources[sources.count - 1]
                var kerning: Double = 0
                if pending.count == 1 && pending[0] >= 0 && pending[0] == previous && from == previous + 1 {
                    // The same two glyphs with the same space between them: the original adjustment.
                    kerning = old[previous].kerningAfter
                } else if pending.count > 0 {
                    // PDFium must still read the gap as a space; widen it only when it might not.
                    let amount = try sumOfGaps(pending)
                    let needed = Self.spaceThreshold(font, self.width, code)
                    kerning = -(amount < needed * 1.02 ? needed * 1.25 : amount)
                } else if previous >= 0 && from == previous + 1 && old[from].show == old[previous].show && !old[previous].spaceAfter {
                    kerning = old[previous].kerningAfter
                }

                glyphs[glyphs.count - 1].kerningAfter = kerning
            }

            glyphs.append(PlannedGlyph(code, width, 0))
            sources.append(from)
            pending.removeAll()
        }

        // An old glyph whose whole text the new text keeps at this position.
        func reusedGlyph(_ start: Int) -> Int? {
            let at = aligned[start]
            if at < 0 {
                return nil
            }

            let first = oldChars[at]
            if first.kind != .glyph || first.offset != 0 || !old[first.glyph].reusable {
                return nil
            }

            let text = old[first.glyph].text.units
            var t = 1
            while t < text.count {
                if start + t >= units.count || aligned[start + t] != at + t {
                    return nil
                }

                t += 1
            }

            return first.glyph
        }

        while j < units.count {
            let c = units[j]
            let at = aligned[j]
            let source = at >= 0 ? oldChars[at] : OldChar(0, .glyph, 0, 0)
            if Self.isSpace(c) {
                j += 1
                if at >= 0 && source.kind == .gap {
                    pending.append(source.glyph)
                } else if at >= 0 && source.kind == .glyph && old[source.glyph].text.ordinalEquals(" ") && old[source.glyph].reusable {
                    let space = old[source.glyph]
                    try add(space.code, space.width, source.glyph)
                } else if let code = spaceCode, let width = self.width(code) {
                    try add(code, width, -1)
                } else {
                    pending.append(-1)
                }

                continue
            }

            if let reused = reusedGlyph(j) {
                try add(old[reused].code, old[reused].width, reused)
                j += old[reused].text.length
                visible = glyphs.count
                continue
            }

            let encoded = encode(units, j)
            guard let codes = encoded.codes, codes.count == 1 else {
                // The character itself: a surrogate pair, or one char.
                let count = DotNetChar.isSurrogatePair(units, j) ? 2 : 1
                let text = String(units: units[j..<(j + count)])
                if !missing.contains(where: { $0.ordinalEquals(text) }) {
                    missing.append(text)
                }

                j += count
                continue
            }

            let single = codes[0]
            fresh.append((text: String(units: units[j..<(j + encoded.length)]), code: single))
            try add(single, self.width(single) ?? .nan, -1)
            j += encoded.length
            visible = glyphs.count
        }

        let trailing = try pending.count > 0 ? -sumOfGaps(pending) : 0
        return GlyphPlan(
            initialKerning: initial,
            glyphs: glyphs,
            trailingKerning: trailing,
            visibleGlyphs: visible,
            missing: missing,
            newGlyphs: fresh)
    }

    /// The smallest gap before a code, in thousandths of an em, that PDFium reads as a space (cpdf_textpage.cpp).
    static func spaceThreshold(_ font: PdfFontInfo, _ width: (UInt32) -> Double?, _ next: UInt32) -> Double {
        var threshold: Double = 0
        if let space = font.firstCodeFor(" "), let spaceWidth = width(space) {
            threshold = spaceWidth * 1000 > 1000.0 / 3 ? 0 : spaceWidth * 1000 / 2
        }

        if threshold <= 0 {
            let w = (width(next) ?? 0) * 1000
            threshold = w < 300 ? w / 2 : w < 500 ? w / 4 : w < 700 ? w / 5 : w / 6
        }

        return threshold
    }

    /// Reads the glyphs of the text objects being replaced, matching them to the text PDFium reads
    /// for each object (`pieces`), which includes a space wherever PDFium reads a TJ adjustment as
    /// one. Returns nil when the two don't match exactly.
    static func readOldGlyphs(
        _ shows: [ShowOp],
        _ pieces: [TextPiece],
        _ separators: [String],
        _ width: (ShowOp, UInt32) -> Double?,
        _ edited: ShowOp
    ) throws -> [OldGlyph]? {
        var glyphs: [OldGlyph] = []
        for s in 0..<shows.count {
            let show = shows[s]
            guard let font = show.font, pieces[s].hasCharacters else {
                return nil
            }

            let text = try TextEquivalence.normalize(pieces[s].text).units
            let codes = show.codes()
            let reusable = font === edited.font && show.fontSize == edited.fontSize && show.charSpace == edited.charSpace
                && show.wordSpace == edited.wordSpace && show.horizontalScale == edited.horizontalScale && show.rise == edited.rise
            var position = 0
            for i in 0..<codes.count {
                let (code, kerning) = codes[i]
                guard let unicode = font.unicode(code), unicode.length > 0, let w = width(show, code) else {
                    return nil
                }

                let glyphText = try TextEquivalence.normalize(Encodings.expandLigatures(unicode)).units
                if position + glyphText.count > text.count || !text[position..<(position + glyphText.count)].elementsEqual(glyphText) {
                    return nil
                }

                position += glyphText.count

                // PDFium adds a space for a large enough adjustment after a glyph, before the next one.
                var spaceAfter = i < codes.count - 1 && kerning != 0 && position < text.count && text[position] == 0x20
                if spaceAfter, let next = font.unicode(codes[i + 1].code), next.utf16.first == 0x20,
                    position + 1 >= text.count || text[position + 1] != 0x20 {
                    spaceAfter = false
                }

                if spaceAfter {
                    position += 1
                }

                let comparableText = try comparable(unicode)
                var separatorBefore = false
                if i == 0 && s > 0 {
                    guard s - 1 < separators.count else {
                        throw DotNetThrows.listIndexOutOfRange()
                    }

                    separatorBefore = separators[s - 1].ordinalEquals(" ")
                }

                glyphs.append(OldGlyph(code, w, kerning, comparableText, s, spaceAfter, separatorBefore, reusable))
            }

            if position != text.count {
                return nil
            }
        }

        return glyphs
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0xA0 }

    /// Text as alignment compares it: ligatures as their letters, as PDFium reads them, and a
    /// no-break space and a space may stand in for each other, as `PdfFontInfo.encode` lets them,
    /// but other spaces differ (an ideographic space is a full em wide).
    private static func comparable(_ text: String) throws -> String {
        try DotNetNormalization.formC(Encodings.expandLigatures(text)).ordinalReplacing("\u{A0}", with: " ")
    }

    private static func oldCharacters(_ old: [OldGlyph]) -> [OldChar] {
        var chars: [OldChar] = []
        for k in 0..<old.count {
            if old[k].separatorBefore {
                chars.append(OldChar(0x20, .separator, -1, 0))
            }

            let text = old[k].text.units
            for t in 0..<text.count {
                chars.append(OldChar(text[t], .glyph, k, t))
            }

            if old[k].spaceAfter {
                chars.append(OldChar(0x20, .gap, k, 0))
            }
        }

        return chars
    }

    /// For each character of the new text, the old character it keeps (a longest common subsequence), or -1.
    private static func align(_ old: [OldChar], _ text: String) throws -> [Int] {
        let m = text.length
        var result = [Int](repeating: -1, count: m)
        let n = old.count
        if n == 0 || m == 0 || (n + 1) * (m + 1) > maxAlignmentCells {
            return result
        }

        let normalized = try comparable(text).units
        if normalized.count != m {
            return result
        }

        var lengths = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        var i = n - 1
        while i >= 0 {
            var k = m - 1
            while k >= 0 {
                lengths[(i * (m + 1)) + k] = old[i].c == normalized[k]
                    ? lengths[((i + 1) * (m + 1)) + k + 1] + 1
                    : max(lengths[((i + 1) * (m + 1)) + k], lengths[(i * (m + 1)) + k + 1])
                k -= 1
            }

            i -= 1
        }

        i = 0
        var k = 0
        while i < n && k < m {
            if old[i].c == normalized[k] {
                result[k] = i
                k += 1
                i += 1
            } else if lengths[((i + 1) * (m + 1)) + k] >= lengths[(i * (m + 1)) + k + 1] {
                i += 1
            } else {
                k += 1
            }
        }

        return result
    }

    /// The width of a gap, in thousandths of an em: an old gap it keeps, or the font's usual word gap.
    private func gap(_ oldGlyph: Int) throws -> Double {
        if oldGlyph >= 0, let old {
            return -old[oldGlyph].kerningAfter
        }

        return try wordGap()
    }

    /// C#'s `pending.Sum(Gap)`: the gaps added in order, starting from 0.
    private func sumOfGaps(_ gaps: [Int]) throws -> Double {
        var total: Double = 0
        for oldGlyph in gaps {
            total += try gap(oldGlyph)
        }

        return total
    }

    /// Codes for the character at `start`, or for a ligature starting there when the font draws the characters only together.
    private func encode(_ text: [UInt16], _ start: Int) -> (codes: [UInt32]?, length: Int) {
        let length = DotNetChar.isSurrogatePair(text, start) ? 2 : 1
        var missing: [String] = []
        let codes = font.encode(String(units: text[start..<(start + length)]), preferred, &missing)
        if missing.isEmpty {
            return (codes, length)
        }

        var ligature = 3
        while ligature >= 2 {
            if start + ligature <= text.count, let code = font.codeFor(String(units: text[start..<(start + ligature)]), preferred) {
                return ([code], ligature)
            }

            ligature -= 1
        }

        return (nil, length)
    }

    private enum CharKind {
        case glyph
        case gap
        case separator
    }

    private struct OldChar {
        let c: UInt16

        let kind: CharKind

        let glyph: Int

        let offset: Int

        init(_ c: UInt16, _ kind: CharKind, _ glyph: Int, _ offset: Int) {
            self.c = c
            self.kind = kind
            self.glyph = glyph
            self.offset = offset
        }
    }
}
