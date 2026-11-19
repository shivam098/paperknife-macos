import CPDFium

final class TextSupportResult: Sendable {
    init(_ problem: String?, _ characters: [String]) {
        self.problem = problem
        self.characters = characters
    }

    static let supported = TextSupportResult(nil, [])

    let problem: String?

    let characters: [String]

    var isSupported: Bool { problem == nil }
}

/// Decides, before anything changes, whether new text can be drawn with the font a text object
/// already uses. PDFium's `FPDFText_SetText` silently turns characters it can't encode into
/// character code 0, so these checks (and a round-trip check after the edit) prevent garbage text.
enum TextSupport {
    // A Unicode noncharacter that fonts don't map, so it resolves to the font's .notdef glyph.
    private static let missingGlyphProbe: UInt32 = 0xFFFF
    private static let probeSize: Float = 12

    /// - Parameter checkGlyphs: False to check only the layout rules. PDFium can't outline Type 3
    ///   glyphs, so their characters are checked against the font's glyph procedures instead.
    static func check(_ font: FPDF_FONT?, _ fontName: String, _ text: String, checkGlyphs: Bool = true) -> TextSupportResult {
        guard let font else {
            return TextSupportResult("This text has no usable font, so it can't be edited.", [])
        }

        let layout = distinct(text, isLayoutCharacter)
        if !layout.isEmpty {
            return TextSupportResult("Line breaks and tabs can't be added to a single line of text yet.", layout)
        }

        if text.utf16.contains(where: DotNetChar.isSurrogate) {
            let runes = text.unicodeScalars.filter { $0.value > 0xFFFF }.map { String($0) }.distinctInOrder { OrdinalString($0) }
            return TextSupportResult("Emoji and other characters outside the Basic Multilingual Plane aren't supported yet.", runes)
        }

        let shaping = distinct(text, needsShaping)
        if !shaping.isEmpty {
            return TextSupportResult("Scripts that need text shaping (for example Hindi, Arabic or Thai) can't be edited yet.", shaping)
        }

        let missing = checkGlyphs ? findMissingGlyphs(font, text) : []
        if !missing.isEmpty {
            return TextSupportResult(missingMessage(fontName, missing), missing)
        }

        return TextSupportResult.supported
    }

    /// The message for characters a font can't draw, naming the ones that are invisible.
    static func missingMessage(_ fontName: String, _ characters: [String]) -> String {
        "The font “\(fontName)” in this PDF doesn't contain: \(characters.map { describe($0) }.joined(separator: ", "))"
    }

    private static func isLayoutCharacter(_ c: UInt16) -> Bool {
        if DotNetChar.isControl(c) {
            return true
        }

        let category = DotNetChar.category(c)
        return category == .lineSeparator || category == .paragraphSeparator
    }

    private static func needsShaping(_ c: UInt16) -> Bool {
        switch DotNetChar.category(c) {
        case .nonSpacingMark, .spacingCombiningMark, .enclosingMark, .format:
            return true
        default:
            break
        }

        switch c {
        case 0x0590...0x08FF: return true // Hebrew, Arabic, Syriac, Thaana, NKo and related
        case 0x0900...0x0DFF: return true // Devanagari through Sinhala
        case 0x0E00...0x0FFF: return true // Thai, Lao, Tibetan
        case 0x1000...0x109F: return true // Myanmar
        case 0x1780...0x18AF: return true // Khmer, Mongolian
        case 0xFB1D...0xFDFF: return true // Hebrew and Arabic presentation forms
        case 0xFE70...0xFEFF: return true // Arabic presentation forms B
        default: return false
        }
    }

    private static func findMissingGlyphs(_ font: FPDF_FONT, _ text: String) -> [String] {
        var missing: [String] = []
        let notDef = glyphOutline(font, missingGlyphProbe)
        var seen = Set<UInt16>()
        for c in text.utf16 {
            if !seen.insert(c).inserted {
                continue
            }

            var width: Float = 0
            var drawable = FPDFFont_GetGlyphWidth(font, UInt32(c), probeSize, &width) != 0 && width > 0
            if drawable {
                let outline = glyphOutline(font, UInt32(c))
                if DotNetChar.isWhiteSpace(c) {
                    // A real space draws nothing. An outline means PDFium fell back to the
                    // font's missing-glyph shape (usually a box), which takes up width too.
                    drawable = outline?.isEmpty ?? true
                } else if let outline, !outline.isEmpty {
                    if let notDef, !notDef.isEmpty {
                        drawable = !outline.dotNetSequenceEqual(notDef)
                    } else {
                        drawable = true
                    }
                } else {
                    drawable = false
                }
            }

            if !drawable {
                missing.append(String(units: [c]))
            }
        }

        return missing
    }

    /// A comparable signature of a glyph's outline, or nil when PDFium has no glyph at all.
    private static func glyphOutline(_ font: FPDF_FONT, _ codePoint: UInt32) -> [Float]? {
        guard let path = FPDFFont_GetGlyphPath(font, codePoint, probeSize) else {
            return nil
        }

        let count = Int(FPDFGlyphPath_CountGlyphSegments(path))
        if count <= 0 {
            return []
        }

        var outline = [Float](repeating: 0, count: count * 3)
        for i in 0..<count {
            let segment = FPDFGlyphPath_GetGlyphPathSegment(path, Int32(i))
            var x: Float = 0
            var y: Float = 0
            if let segment {
                FPDFPathSegment_GetPoint(segment, &x, &y)
            }

            outline[i * 3] = segment == nil ? -1 : Float(FPDFPathSegment_GetType(segment))
            outline[(i * 3) + 1] = x
            outline[(i * 3) + 2] = y
        }

        return outline
    }

    private static func distinct(_ text: String, _ predicate: (UInt16) -> Bool) -> [String] {
        text.utf16.filter(predicate).map { describe(String(units: [$0])) }.distinctInOrder { OrdinalString($0) }
    }

    private static func describe(_ text: String) -> String {
        let units = text.units
        switch units {
        case [0x0A], [0x0D], [0x2028]:
            return "line break"
        case [0x2029]:
            return "paragraph break"
        case [0x09]:
            return "tab"
        case [0x20]:
            return "space"
        case [0xA0]:
            return "no-break space"
        default:
            break
        }

        if units.count == 1
            && (DotNetChar.isWhiteSpace(units[0]) || DotNetChar.isControl(units[0]) || DotNetChar.category(units[0]) == .format) {
            let hex = String(units[0], radix: 16, uppercase: true)
            return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        }

        return text
    }
}
