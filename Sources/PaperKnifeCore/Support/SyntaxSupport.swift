import Foundation

// .NET behaviour the Syntax, Content and Fonts layers rely on, beyond DotNetText and DotNetMath.

// MARK: - Exceptions

/// C#'s `IndexOutOfRangeException`: an array or span indexed outside its bounds. PaperKnife's own
/// reader can hit one on crafted files; DocumentSession treats it as a read failure.
final class IndexOutOfRangeException: DotNetException, @unchecked Sendable {
    init() {
        super.init("Index was outside the bounds of the array.")
    }
}

/// C#'s `NullReferenceException`, which DocumentSession treats as a read failure.
final class NullReferenceException: DotNetException, @unchecked Sendable {
    init() {
        super.init("Object reference not set to an instance of an object.")
    }
}

/// C#'s `OverflowException`, for example for an array of negative length; a read failure too.
final class OverflowException: DotNetException, @unchecked Sendable {
    init() {
        super.init("Arithmetic operation resulted in an overflow.")
    }
}

/// C#'s `IOException`. DocumentSession doesn't treat it as a read failure: it reaches the caller.
class IOException: DotNetException, @unchecked Sendable {}

/// .NET's `ZLibException`, an `IOException`: zlib reported something other than damaged data, such
/// as a stream that needs a preset dictionary. Unlike damaged data, StreamFilters doesn't catch it.
final class ZLibException: IOException, @unchecked Sendable {}

/// The exceptions .NET throws where the C# reader can fail, by the C# expression that throws them.
enum DotNetThrows {
    /// `array[index]` or `span[index]` outside the bounds.
    static func indexOutOfRange() -> Error { IndexOutOfRangeException() }

    /// `list[index]` outside the bounds of a `List<T>`.
    static func listIndexOutOfRange() -> Error {
        ArgumentOutOfRangeException("index", nil, "Index was out of range. Must be non-negative and less than the size of the collection.")
    }

    /// A span sliced outside its bounds.
    static func spanOutOfRange() -> Error { ArgumentOutOfRangeException(nil) }

    /// `Enumerable.Max` (and the like) of an empty sequence.
    static func noElements() -> Error { InvalidOperationException("Sequence contains no elements") }

    /// `new ArgumentException(message, paramName)`.
    static func argument(_ message: String, _ paramName: String) -> Error { ArgumentException(message, paramName) }

    /// A member of a null reference.
    static func nullReference() -> Error { NullReferenceException() }

    /// `new T[length]` with a negative length.
    static func overflow() -> Error { OverflowException() }
}

// MARK: - Text

/// .NET's `Encoding.BigEndianUnicode`.
enum Utf16BigEndian {
    /// `GetString`: each unpaired surrogate becomes U+FFFD, and so does an odd last byte.
    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var iterator = bytes.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next() else {
                return String(units: units) + "\u{FFFD}"
            }

            units.append(UInt16(high) << 8 | UInt16(low))
        }

        return String(units: units)
    }
}

/// .NET's `string.Normalize`, which refuses U+FFFE and unpaired surrogates with an
/// `ArgumentException` (Normalization.HasInvalidUnicodeSequence) instead of normalizing them. A
/// Swift string can't hold an unpaired surrogate, so U+FFFE is what can be refused here.
enum DotNetNormalization {
    /// `Normalize()`, or `Normalize(NormalizationForm.FormC)`.
    static func formC(_ text: String) throws -> String {
        try check(text)
        return text.normalizedFormC
    }

    /// `Normalize(NormalizationForm.FormKC)`.
    static func formKC(_ text: String) throws -> String {
        try check(text)
        return text.normalizedFormKC
    }

    private static func check(_ text: String) throws {
        if text.utf16.contains(0xFFFE) {
            throw ArgumentException("Invalid Unicode code point found.", "strInput")
        }
    }
}

/// .NET's number formats where they differ from Swift's `String(_:)`.
enum DotNetFormat {
    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// `value.ToString("D<digits>")`: at least `digits` digits, after a minus sign when negative.
    static func d(_ value: Int, _ digits: Int) -> String {
        let magnitude = String(value.magnitude)
        let padded = String(repeating: "0", count: max(0, digits - magnitude.count)) + magnitude
        return value < 0 ? "-" + padded : padded
    }

    /// `b.ToString("X2")`.
    static func x2(_ b: UInt8) -> String {
        String(decoding: [hexDigits[Int(b >> 4)], hexDigits[Int(b & 15)]], as: UTF8.self)
    }

    /// `Convert.ToHexString`: two uppercase digits per byte.
    static func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var text: [UInt8] = []
        text.reserveCapacity(bytes.count * 2)
        for b in bytes {
            text.append(hexDigits[Int(b >> 4)])
            text.append(hexDigits[Int(b & 15)])
        }

        return String(decoding: text, as: UTF8.self)
    }
}

extension DotNetParse {
    /// .NET's `IsWhite` for numbers: U+0009 to U+000D and U+0020 (not every `char.IsWhiteSpace`).
    private static func isNumberWhite(_ unit: UInt16) -> Bool { unit == 0x20 || (unit >= 0x09 && unit <= 0x0D) }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    /// `int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, ...)`: an
    /// optional sign and decimal digits, nothing else (but the trailing NULs .NET ignores), within
    /// the range of a 32-bit integer.
    static func signedInt32<C: Collection>(_ units: C) -> Int? where C.Element == UInt16 {
        var rest = Array(units)[...]
        var negative = false
        if let first = rest.first, first == 0x2B || first == 0x2D {
            negative = first == 0x2D
            rest = rest.dropFirst()
        }

        var value: Int64 = 0
        var digits = 0
        while let unit = rest.first, isDigit(unit) {
            value = value * 10 + Int64(unit - 0x30)
            if value > Int64(Int32.max) + 1 {
                return nil
            }

            digits += 1
            rest = rest.dropFirst()
        }

        guard digits > 0, rest.allSatisfy({ $0 == 0 }) else {
            return nil
        }

        value = negative ? -value : value
        return value >= Int64(Int32.min) && value <= Int64(Int32.max) ? Int(value) : nil
    }

    /// `double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, ...)`: white space
    /// around an optional sign, digits with at most one decimal point and an optional exponent, or
    /// the symbols of infinity and NaN; correctly rounded, as .NET Core rounds.
    static func double<C: Collection>(_ units: C) -> Double? where C.Element == UInt16 {
        let all = Array(units)
        var i = 0
        while i < all.count && isNumberWhite(all[i]) {
            i += 1
        }

        // A sign, which white space may not follow.
        var negative = false
        if i < all.count && (all[i] == 0x2B || all[i] == 0x2D) {
            negative = all[i] == 0x2D
            i += 1
        }

        var integral: [UInt8] = []
        while i < all.count && isDigit(all[i]) {
            integral.append(UInt8(all[i]))
            i += 1
        }

        var fraction: [UInt8] = []
        if i < all.count && all[i] == 0x2E {
            i += 1
            while i < all.count && isDigit(all[i]) {
                fraction.append(UInt8(all[i]))
                i += 1
            }
        }

        guard !integral.isEmpty || !fraction.isEmpty else {
            return symbol(all)
        }

        var exponent: [UInt8] = []
        if i < all.count && (all[i] == 0x45 || all[i] == 0x65) {
            var j = i + 1
            var exponentSign: UInt8?
            if j < all.count && (all[j] == 0x2B || all[j] == 0x2D) {
                exponentSign = UInt8(all[j])
                j += 1
            }

            var digits: [UInt8] = []
            while j < all.count && isDigit(all[j]) {
                digits.append(UInt8(all[j]))
                j += 1
            }

            // Without digits, the "e" isn't part of the number, and then fails it as a trailing character.
            if !digits.isEmpty {
                exponent = [0x65] + (exponentSign.map { [$0] } ?? []) + digits
                i = j
            }
        }

        while i < all.count && isNumberWhite(all[i]) {
            i += 1
        }

        guard all[i...].allSatisfy({ $0 == 0 }) else {
            return symbol(all)
        }

        // A canonical spelling strtod reads exactly: digits on both sides of the point.
        let mantissa = (integral.isEmpty ? [0x30] : integral) + [0x2E] + (fraction.isEmpty ? [0x30] : fraction)
        let text = String(decoding: (negative ? [0x2D] : []) + mantissa + exponent, as: UTF8.self)
        return Double(text)
    }

    /// The symbols .NET's invariant culture parses after the digits fail: "Infinity", "-Infinity",
    /// "NaN", "+Infinity", "+NaN" and "-NaN", in any case, with white space around them.
    private static func symbol(_ all: [UInt16]) -> Double? {
        let start = all.firstIndex { !DotNetChar.isWhiteSpace($0) } ?? all.count
        let end = all.lastIndex { !DotNetChar.isWhiteSpace($0) }.map { $0 + 1 } ?? start
        guard start < end else {
            return nil
        }

        // Ordinal case-insensitive: the invariant simple uppercase of each char.
        let upper = all[start..<end].map { unit -> UInt16 in
            switch unit {
            case 0x61...0x7A: return unit - 0x20
            case 0x131: return 0x49
            case 0x17F: return 0x53
            default: return unit
            }
        }

        switch String(units: upper) {
        case "INFINITY", "+INFINITY": return .infinity
        case "-INFINITY": return -.infinity
        case "NAN", "+NAN", "-NAN": return .nan
        default: return nil
        }
    }
}

extension DotNetMath {
    /// C#'s `(uint)value`: truncated, saturated to the range of `uint`, and 0 for NaN.
    static func toUInt32(_ value: Double) -> UInt32 {
        if value.isNaN || value <= 0 {
            return 0
        }

        if value >= 4_294_967_295.0 {
            return .max
        }

        return UInt32(value.rounded(.towardZero))
    }
}
