import Foundation

/// Compares text the way a reader sees it. Fonts often share one glyph between several code points
/// (for example U+0020 SPACE and U+00A0 NO-BREAK SPACE), so text read back from a PDF can differ
/// from what was written without any visible difference. Only canonically equivalent characters
/// (NFC, which also maps U+2126 OHM SIGN to U+03A9) and space separators are treated as equal;
/// compatibility variants such as "²" and "2" or "…" and "..." stay different because they look
/// different.
enum TextEquivalence {
    static func areEquivalent(_ a: String, _ b: String) -> Bool { normalize(a).ordinalEquals(normalize(b)) }

    /// Like `areEquivalent`, but ignores how much whitespace separates words and any at the ends.
    /// PDFium's text extraction skips text objects that draw only spaces and reports gaps as single
    /// generated spaces, so the spacing of rewritten text can't be read back exactly. Every space
    /// is checked to be drawable before it is written (see `TextSupport`).
    static func areEquivalentIgnoringSpacing(_ a: String, _ b: String) -> Bool {
        collapseSpaces(normalize(a)).ordinalEquals(collapseSpaces(normalize(b)))
    }

    static func normalize(_ text: String) -> String {
        let normalized = text.normalizedFormC
        return String(units: normalized.utf16.map { DotNetChar.category($0) == .spaceSeparator ? 0x20 : $0 })
    }

    /// Characters of `expected` that are missing from `actual`. Throws where C# does: C#'s
    /// `Normalize` refuses a lone surrogate, which is what each char of a pair is on its own.
    static func lost(_ expected: String, _ actual: String) throws -> [String] {
        let have = normalize(actual)
        var lost: [String] = []
        for c in expected.utf16 {
            if DotNetChar.isSurrogate(c) {
                throw ArgumentException("Invalid Unicode code point found.", "strInput")
            }

            let character = String(units: [c])
            if !have.ordinalContains(normalize(character)) {
                lost.append(character)
            }
        }

        return lost.distinctInOrder { OrdinalString($0) }
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
