import Foundation

/// Compares text the way a reader sees it. Fonts often share one glyph between several code points
/// (for example U+0020 SPACE and U+00A0 NO-BREAK SPACE), so text read back from a PDF can differ
/// from what was written without any visible difference. Only canonically equivalent characters
/// (NFC, which also maps U+2126 OHM SIGN to U+03A9) and space separators are treated as equal;
/// compatibility variants such as "²" and "2" or "…" and "..." stay different because they look
/// different.
///
/// Text .NET can't normalize (with U+FFFE or an unpaired surrogate) compares as it is, as in C#.
/// A Swift string can't hold an unpaired surrogate, but each char of a surrogate pair is one on
/// its own, so `lost` works on code units.
enum TextEquivalence {
    static func areEquivalent(_ a: String, _ b: String) -> Bool {
        normalize(a).ordinalEquals(normalize(b))
    }

    /// Like `areEquivalent`, but ignores how much whitespace separates words and any at the ends.
    /// PDFium's text extraction skips text objects that draw only spaces and reports gaps as single
    /// generated spaces, so the spacing of rewritten text can't be read back exactly. Every space
    /// is checked to be drawable before it is written (see `TextSupport`).
    static func areEquivalentIgnoringSpacing(_ a: String, _ b: String) -> Bool {
        collapseSpaces(normalize(a)).ordinalEquals(collapseSpaces(normalize(b)))
    }

    static func normalize(_ text: String) -> String {
        String(units: normalize(units: text.utf16))
    }

    /// Characters of `expected` that are missing from `actual`.
    static func lost(_ expected: String, _ actual: String) -> [String] {
        let have = normalize(units: actual.utf16)
        var lost: [UInt16] = []
        for c in expected.utf16 where !contains(have, normalize(units: [c])) && !lost.contains(c) {
            lost.append(c)
        }

        return lost.map { String(units: [$0]) }
    }

    /// C#'s `Normalize`: the code units in NFC, with space separators made spaces.
    private static func normalize<C: Collection>(units: C) -> [UInt16] where C.Element == UInt16 {
        let normalized = tryNormalize(units) ?? Array(units)
        return normalized.map { DotNetChar.category($0) == .spaceSeparator ? 0x20 : $0 }
    }

    /// The text in NFC, or nil when .NET can't normalize it because it has U+FFFE or an unpaired
    /// surrogate, as pasted text or a PDF's character map can. Such text compares as it is.
    private static func tryNormalize<C: Collection>(_ units: C) -> [UInt16]? where C.Element == UInt16 {
        // .NET's check before it normalizes non-ASCII text (Normalization.HasInvalidUnicodeSequence).
        var i = units.startIndex
        while i != units.endIndex {
            let c = units[i]
            let next = units.index(after: i)
            if c == 0xFFFE || DotNetChar.isLowSurrogate(c)
                || (DotNetChar.isHighSurrogate(c) && (next == units.endIndex || !DotNetChar.isLowSurrogate(units[next]))) {
                return nil
            }

            i = DotNetChar.isHighSurrogate(c) ? units.index(after: next) : next
        }

        return Array(String(units: units).normalizedFormC.utf16)
    }

    /// C#'s ordinal `Contains`: whether `value`'s code units occur in `text`'s.
    private static func contains(_ text: [UInt16], _ value: [UInt16]) -> Bool {
        if value.isEmpty {
            return true
        }

        var i = 0
        while i + value.count <= text.count {
            if text[i..<(i + value.count)].elementsEqual(value) {
                return true
            }

            i += 1
        }

        return false
    }

    /// C#'s `string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))`:
    /// the words between `char.IsWhiteSpace` characters, one space apart.
    private static func collapseSpaces(_ text: String) -> String {
        var words: [[UInt16]] = []
        var word: [UInt16] = []
        for unit in text.utf16 {
            if DotNetChar.isWhiteSpace(unit) {
                if !word.isEmpty {
                    words.append(word)
                    word = []
                }
            } else {
                word.append(unit)
            }
        }

        if !word.isEmpty {
            words.append(word)
        }

        return String(units: Array(words.joined(separator: [0x20])))
    }
}
