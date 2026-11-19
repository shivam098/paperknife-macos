import Foundation

// .NET semantics the PDFium layer needs beyond those in DotNetMath.swift and DotNetText.swift.

extension DotNetMath {
    /// `Math.Max(x, y)` for `float`: NaN when either is NaN, and +0 above -0 (IEEE 754:2019
    /// `maximum`). Swift's `max` returns its first argument for NaN and for two zeros.
    static func maximum(_ x: Float, _ y: Float) -> Float {
        if x != y {
            if !x.isNaN {
                return y < x ? x : y
            }

            return x
        }

        return y.sign == .minus ? x : y
    }

    /// `Math.Max(x, y)` for `double` (see the `float` overload).
    static func maximum(_ x: Double, _ y: Double) -> Double {
        if x != y {
            if !x.isNaN {
                return y < x ? x : y
            }

            return x
        }

        return y.sign == .minus ? x : y
    }

    /// `Math.Min(x, y)` for `float`: NaN when either is NaN, and -0 below +0 (IEEE 754:2019
    /// `minimum`).
    static func minimum(_ x: Float, _ y: Float) -> Float {
        if x != y {
            if !x.isNaN {
                return x < y ? x : y
            }

            return x
        }

        return x.sign == .minus ? x : y
    }

    /// `Math.Min(x, y)` for `double` (see the `float` overload).
    static func minimum(_ x: Double, _ y: Double) -> Double {
        if x != y {
            if !x.isNaN {
                return x < y ? x : y
            }

            return x
        }

        return x.sign == .minus ? x : y
    }

    /// `float.Equals(x, y)`, which records, `EqualityComparer<float>.Default` and `SequenceEqual`
    /// use: unlike `==`, NaN equals NaN.
    static func equals(_ x: Float, _ y: Float) -> Bool { x == y || (x.isNaN && y.isNaN) }
}

extension Array where Element == Float {
    /// C#'s `SequenceEqual` on floats, which compares them with `float.Equals`: NaN equals NaN.
    func dotNetSequenceEqual(_ other: [Float]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { DotNetMath.equals($0, $1) }
    }
}

/// .NET's `Encoding.UTF8`.
enum Utf8 {
    /// `Encoding.UTF8.GetString(bytes)`. Each maximal subpart of an ill-formed sequence becomes one
    /// U+FFFD, as .NET replaces them (Unicode 3.9, "U+FFFD Substitution of Maximal Subparts").
    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let input = Array(bytes)
        var units: [UInt16] = []
        units.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let lead = input[i]
            if lead < 0x80 {
                units.append(UInt16(lead))
                i += 1
                continue
            }

            // How many bytes the lead byte starts, and the range of the byte after it (table 3-7).
            let length: Int
            var low: UInt8 = 0x80
            var high: UInt8 = 0xBF
            switch lead {
            case 0xC2...0xDF:
                length = 2
            case 0xE0:
                length = 3
                low = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF:
                length = 3
            case 0xED:
                length = 3
                high = 0x9F
            case 0xF0:
                length = 4
                low = 0x90
            case 0xF1...0xF3:
                length = 4
            case 0xF4:
                length = 4
                high = 0x8F
            default:
                units.append(0xFFFD)
                i += 1
                continue
            }

            var scalar = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
            var next = 1
            while next < length, i + next < input.count, input[i + next] >= low, input[i + next] <= high {
                scalar = (scalar << 6) | UInt32(input[i + next] & 0x3F)
                next += 1
                low = 0x80
                high = 0xBF
            }

            if next < length {
                units.append(0xFFFD)
            } else if scalar >= 0x10000 {
                units.append(UInt16(0xD800 + ((scalar - 0x10000) >> 10)))
                units.append(UInt16(0xDC00 + ((scalar - 0x10000) & 0x3FF)))
            } else {
                units.append(UInt16(scalar))
            }

            i += next
        }

        return String(units: units)
    }
}
