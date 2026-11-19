import Foundation

/// Compares text the way a reader sees it. Fonts often share one glyph between several code points
/// (for example U+0020 SPACE and U+00A0 NO-BREAK SPACE), so text read back from a PDF can differ
/// from what was written without any visible difference. Only canonically equivalent characters
/// (NFC, which also maps U+2126 OHM SIGN to U+03A9) and space separators are treated as equal;
/// compatibility variants such as "²" and "2" or "…" and "..." stay different because they look
/// different.
///
/// These throw where C# does: .NET's `Normalize` refuses U+FFFE and lone surrogates (which Swift
/// strings can't hold, but each char of a surrogate pair is one on its own).
enum TextEquivalence {
    static func areEquivalent(_ a: String, _ b: String) throws -> Bool {
        let first = try normalize(a)
        let second = try normalize(b)
        return first.ordinalEquals(second)
    }

    /// Like `areEquivalent`, but ignores how much whitespace separates words and any at the ends.
    /// PDFium's text extraction skips text objects that draw only spaces and reports gaps as single
    /// generated spaces, so the spacing of rewritten text can't be read back exactly. Every space
    /// is checked to be drawable before it is written (see `TextSupport`).
    static func areEquivalentIgnoringSpacing(_ a: String, _ b: String) throws -> Bool {
        let first = try normalize(a)
        let second = try normalize(b)
        return collapseSpaces(first).ordinalEquals(collapseSpaces(second))
    }

    static func normalize(_ text: String) throws -> String {
        try normalize(units: text.utf16)
    }

    /// Characters of `expected` that are missing from `actual`.
    static func lost(_ expected: String, _ actual: String) throws -> [String] {
        let have = try normalize(actual)
        var lost: [String] = []
        for c in expected.utf16 {
            let character = try normalize(units: [c])
            if !have.ordinalContains(character) {
                lost.append(String(units: [c]))
            }
        }

        return lost.distinctInOrder { OrdinalString($0) }
    }

    /// C#'s `Normalize(NormalizationForm.FormC)` of a string of these UTF-16 code units, with space
    /// separators made spaces.
    private static func normalize<C: Collection>(units: C) throws -> String where C.Element == UInt16 {
        // .NET's check before it normalizes non-ASCII text (Normalization.HasInvalidUnicodeSequence).
        var i = units.startIndex
        while i != units.endIndex {
            let c = units[i]
            let next = units.index(after: i)
            if c == 0xFFFE || DotNetChar.isLowSurrogate(c)
                || (DotNetChar.isHighSurrogate(c) && (next == units.endIndex || !DotNetChar.isLowSurrogate(units[next]))) {
                throw ArgumentException("Invalid Unicode code point found.", "strInput")
            }

            i = DotNetChar.isHighSurrogate(c) ? units.index(after: next) : next
        }

        let normalized = String(units: units).normalizedFormC
        return String(units: normalized.utf16.map { DotNetChar.category($0) == .spaceSeparator ? 0x20 : $0 })
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
