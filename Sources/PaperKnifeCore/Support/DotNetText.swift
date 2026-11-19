import Foundation

/// .NET's `UnicodeCategory`, in its order.
enum DotNetUnicodeCategory: Int {
    case uppercaseLetter, lowercaseLetter, titlecaseLetter, modifierLetter, otherLetter
    case nonSpacingMark, spacingCombiningMark, enclosingMark
    case decimalDigitNumber, letterNumber, otherNumber
    case spaceSeparator, lineSeparator, paragraphSeparator
    case control, format, surrogate, privateUse
    case connectorPunctuation, dashPunctuation, openPunctuation, closePunctuation
    case initialQuotePunctuation, finalQuotePunctuation, otherPunctuation
    case mathSymbol, currencySymbol, modifierSymbol, otherSymbol, otherNotAssigned
}

/// C#'s `char` predicates for a UTF-16 code unit, which is what a C# `char` is.
enum DotNetChar {
    static func isHighSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }

    static func isLowSurrogate(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }

    static func isSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDFFF }

    /// `char.IsSurrogatePair(string, index)`.
    static func isSurrogatePair(_ units: [UInt16], _ index: Int) -> Bool {
        index >= 0 && index + 1 < units.count && isHighSurrogate(units[index]) && isLowSurrogate(units[index + 1])
    }

    static func isAsciiDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// `char.IsWhiteSpace`: U+0009 to U+000D, U+0020, U+0085, U+00A0, and the separators.
    static func isWhiteSpace(_ c: UInt16) -> Bool {
        if c < 0x100 {
            return c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0xA0 || c == 0x85
        }

        switch category(c) {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    static func isControl(_ c: UInt16) -> Bool { category(c) == .control }

    /// `CharUnicodeInfo.GetUnicodeCategory(char)`: a surrogate code unit is `surrogate`.
    static func category(_ c: UInt16) -> DotNetUnicodeCategory {
        isSurrogate(c) ? .surrogate : category(scalar: UInt32(c))
    }

    /// `CharUnicodeInfo.GetUnicodeCategory(int)` for a scalar value.
    static func category(scalar value: UInt32) -> DotNetUnicodeCategory {
        guard let scalar = Unicode.Scalar(value) else {
            return value >= 0xD800 && value <= 0xDFFF ? .surrogate : .otherNotAssigned
        }

        switch scalar.properties.generalCategory {
        case .uppercaseLetter: return .uppercaseLetter
        case .lowercaseLetter: return .lowercaseLetter
        case .titlecaseLetter: return .titlecaseLetter
        case .modifierLetter: return .modifierLetter
        case .otherLetter: return .otherLetter
        case .nonspacingMark: return .nonSpacingMark
        case .spacingMark: return .spacingCombiningMark
        case .enclosingMark: return .enclosingMark
        case .decimalNumber: return .decimalDigitNumber
        case .letterNumber: return .letterNumber
        case .otherNumber: return .otherNumber
        case .connectorPunctuation: return .connectorPunctuation
        case .dashPunctuation: return .dashPunctuation
        case .openPunctuation: return .openPunctuation
        case .closePunctuation: return .closePunctuation
        case .initialPunctuation: return .initialQuotePunctuation
        case .finalPunctuation: return .finalQuotePunctuation
        case .otherPunctuation: return .otherPunctuation
        case .mathSymbol: return .mathSymbol
        case .currencySymbol: return .currencySymbol
        case .modifierSymbol: return .modifierSymbol
        case .otherSymbol: return .otherSymbol
        case .spaceSeparator: return .spaceSeparator
        case .lineSeparator: return .lineSeparator
        case .paragraphSeparator: return .paragraphSeparator
        case .control: return .control
        case .format: return .format
        case .surrogate: return .surrogate
        case .privateUse: return .privateUse
        case .unassigned: return .otherNotAssigned
        @unknown default: return .otherNotAssigned
        }
    }

    /// `char.ConvertFromUtf32`, or nil where C# throws (surrogates and values past U+10FFFF).
    static func convertFromUtf32(_ value: Int) -> String? {
        guard value >= 0, value <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(value)) else {
            return nil
        }

        return String(scalar)
    }
}

/// C#'s string operations, which work on UTF-16 code units and compare them ordinally. Swift's own
/// `String` operations work on characters and treat canonically equivalent strings as equal
/// ("é" and "e" + U+0301), so ported code uses these wherever C# uses a string operation.
extension String {
    /// The UTF-16 code units: C#'s chars.
    var units: [UInt16] { Array(utf16) }

    /// C#'s `Length`.
    var length: Int { utf16.count }

    init<C: Collection>(units: C) where C.Element == UInt16 {
        self = String(decoding: units, as: UTF16.self)
    }

    func ordinalEquals(_ other: String) -> Bool { utf16.elementsEqual(other.utf16) }

    /// C#'s `string.CompareOrdinal`: negative, zero or positive.
    func ordinalCompare(_ other: String) -> Int {
        var a = utf16.makeIterator()
        var b = other.utf16.makeIterator()
        while true {
            switch (a.next(), b.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?) where x != y: return Int(x) - Int(y)
            default: continue
            }
        }
    }

    static func ordinalLess(_ a: String, _ b: String) -> Bool { a.ordinalCompare(b) < 0 }

    func ordinalHasPrefix(_ prefix: String) -> Bool { utf16.starts(with: prefix.utf16) }

    func ordinalHasSuffix(_ suffix: String) -> Bool { units.reversed().starts(with: suffix.units.reversed()) }

    /// C#'s `IndexOf(value, StringComparison.Ordinal)` from a UTF-16 offset, or nil for -1.
    func ordinalIndexOf(_ value: String, from start: Int = 0) -> Int? {
        let haystack = units
        let needle = value.units
        guard start >= 0, start <= haystack.count else {
            return nil
        }

        if needle.isEmpty {
            return start
        }

        var i = start
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0] && haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return i
            }

            i += 1
        }

        return nil
    }

    /// C#'s `LastIndexOf(value, StringComparison.Ordinal)`, or nil for -1.
    func ordinalLastIndexOf(_ value: String) -> Int? {
        let haystack = units
        let needle = value.units
        if needle.isEmpty {
            return haystack.count
        }

        var i = haystack.count - needle.count
        while i >= 0 {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return i
            }

            i -= 1
        }

        return nil
    }

    func ordinalContains(_ value: String) -> Bool { ordinalIndexOf(value) != nil }

    /// C#'s `Replace(oldValue, newValue)`, which is ordinal.
    func ordinalReplacing(_ oldValue: String, with newValue: String) -> String {
        let source = units
        let target = oldValue.units
        precondition(!target.isEmpty, "C# throws for an empty oldValue.")
        let replacement = newValue.units
        var result: [UInt16] = []
        result.reserveCapacity(source.count)
        var i = 0
        while i < source.count {
            if i + target.count <= source.count && source[i..<(i + target.count)].elementsEqual(target) {
                result.append(contentsOf: replacement)
                i += target.count
            } else {
                result.append(source[i])
                i += 1
            }
        }

        return String(units: result)
    }

    /// C#'s `Substring(start, length)` in UTF-16 code units.
    func substring(_ start: Int, _ length: Int? = nil) -> String {
        let all = units
        let end = length.map { start + $0 } ?? all.count
        precondition(start >= 0 && start <= end && end <= all.count, "C# throws for this range.")
        return String(units: all[start..<end])
    }

    /// C#'s `Split(char)`: empty entries are kept.
    func split(onUnit separator: UInt16) -> [String] {
        units.split(separator: separator, omittingEmptySubsequences: false).map { String(units: $0) }
    }

    /// C#'s `Trim()`, which removes `char.IsWhiteSpace` characters.
    func dotNetTrim() -> String { dotNetTrimEnd().dotNetTrimStart() }

    /// C#'s `TrimStart()`.
    func dotNetTrimStart() -> String {
        let all = units
        let start = all.firstIndex { !DotNetChar.isWhiteSpace($0) } ?? all.count
        return String(units: all[start...])
    }

    /// C#'s `TrimEnd()`.
    func dotNetTrimEnd() -> String {
        let all = units
        let end = all.lastIndex { !DotNetChar.isWhiteSpace($0) }.map { $0 + 1 } ?? 0
        return String(units: all[..<end])
    }

    /// C#'s `string.IsNullOrWhiteSpace` for a non-null string.
    var isDotNetWhiteSpace: Bool { utf16.allSatisfy(DotNetChar.isWhiteSpace) }

    /// C#'s `Normalize(NormalizationForm.FormC)`.
    var normalizedFormC: String { precomposedStringWithCanonicalMapping }

    /// C#'s `Normalize(NormalizationForm.FormKC)`.
    var normalizedFormKC: String { precomposedStringWithCompatibilityMapping }
}

/// A string as a C# dictionary or set key: equal only when its UTF-16 code units are, and ordered
/// by them. Use it for keys that hold text, which may differ only by canonical equivalence.
struct OrdinalString: Hashable, Comparable, CustomStringConvertible {
    let value: String
    private let codeUnits: [UInt16]

    init(_ value: String) {
        self.value = value
        codeUnits = value.units
    }

    var description: String { value }

    static func == (a: OrdinalString, b: OrdinalString) -> Bool { a.codeUnits == b.codeUnits }

    static func < (a: OrdinalString, b: OrdinalString) -> Bool { a.codeUnits.lexicographicallyPrecedes(b.codeUnits) }

    func hash(into hasher: inout Hasher) { hasher.combine(codeUnits) }
}

/// .NET's `Encoding.Latin1`.
enum Latin1 {
    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(units: bytes.map(UInt16.init))
    }

    /// The bytes of a string; characters past U+00FF become "?", as .NET encodes them.
    static func bytes(_ text: String) -> [UInt8] {
        text.utf16.map { $0 <= 0xFF ? UInt8($0) : 0x3F }
    }
}

/// .NET's integer parsing, which accepts less than Swift's `Int(_:radix:)` does.
enum DotNetParse {
    /// `int.TryParse(text, NumberStyles.AllowHexSpecifier, ...)`: one to eight hex digits, nothing
    /// else but the trailing NULs .NET ignores; eight digits above 7FFFFFFF give negative numbers,
    /// as in C#.
    static func hexInt32<C: Collection>(_ units: C) -> Int? where C.Element == UInt16 {
        guard !units.isEmpty else {
            return nil
        }

        var value: UInt64 = 0
        var index = units.startIndex
        while index != units.endIndex {
            let unit = units[index]
            let digit: UInt64
            switch unit {
            case 0x30...0x39: digit = UInt64(unit - 0x30)
            case 0x41...0x46: digit = UInt64(unit - 0x41 + 10)
            case 0x61...0x66: digit = UInt64(unit - 0x61 + 10)
            default:
                guard index != units.startIndex, units[index...].allSatisfy({ $0 == 0 }) else {
                    return nil
                }

                return Int(Int32(bitPattern: UInt32(value)))
            }

            value = value * 16 + digit
            if value > 0xFFFF_FFFF {
                return nil
            }

            index = units.index(after: index)
        }

        return Int(Int32(bitPattern: UInt32(value)))
    }

    /// `int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, ...)`: optional white
    /// space around an optional sign and decimal digits, within the range of a 32-bit integer.
    static func int32(_ text: String) -> Int? {
        var units = text.dotNetTrim().units[...]
        var negative = false
        if let first = units.first, first == 0x2B || first == 0x2D {
            negative = first == 0x2D
            units = units.dropFirst()
        }

        guard !units.isEmpty else {
            return nil
        }

        var value: Int64 = 0
        for unit in units {
            guard DotNetChar.isAsciiDigit(unit) else {
                return nil
            }

            value = value * 10 + Int64(unit - 0x30)
            if value > Int64(Int32.max) + 1 {
                return nil
            }
        }

        value = negative ? -value : value
        return value >= Int64(Int32.min) && value <= Int64(Int32.max) ? Int(value) : nil
    }
}
