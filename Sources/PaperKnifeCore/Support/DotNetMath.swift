import Foundation

/// .NET's arithmetic where it differs from Swift's: `Math.Round`, casts from floating point to
/// integers (which saturate in .NET instead of trapping), and how `CosWriter` formats numbers.
enum DotNetMath {
    private static let roundLimit = 1e16
    private static let powersOf10: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15]

    /// `Math.Round(value)`: to the nearest integer, ties to even.
    static func round(_ value: Double) -> Double { value.rounded(.toNearestOrEven) }

    /// `Math.Round(value, MidpointRounding.AwayFromZero)`.
    static func roundAwayFromZero(_ value: Double) -> Double { round(value, 0, awayFromZero: true) }

    /// `Math.Round(value, digits)` or, with `awayFromZero`, `Math.Round(value, digits,
    /// MidpointRounding.AwayFromZero)`, computed as .NET computes it (scaled by a power of 10).
    static func round(_ value: Double, _ digits: Int, awayFromZero: Bool = false) -> Double {
        precondition(digits >= 0 && digits <= 15, "C# throws for these digits.")
        guard abs(value) < roundLimit else {
            return value
        }

        let power = powersOf10[digits]
        var scaled = value * power
        scaled = awayFromZero
            ? (scaled + copysign(0.5.nextDown, scaled)).rounded(.towardZero)
            : scaled.rounded(.toNearestOrEven)
        return scaled / power
    }

    /// C#'s `(int)value`: truncated, saturated to the 32-bit range, and 0 for NaN.
    static func toInt32(_ value: Double) -> Int {
        if value.isNaN {
            return 0
        }

        if value >= 2_147_483_647.0 {
            return Int(Int32.max)
        }

        if value <= -2_147_483_648.0 {
            return Int(Int32.min)
        }

        return Int(value.rounded(.towardZero))
    }

    /// C#'s `(int)value` for a `float`.
    static func toInt32(_ value: Float) -> Int { toInt32(Double(value)) }

    /// C#'s `(long)value`: truncated, saturated to the 64-bit range, and 0 for NaN.
    static func toInt64(_ value: Double) -> Int {
        if value.isNaN {
            return 0
        }

        if value >= 9_223_372_036_854_775_807.0 {
            return Int.max
        }

        if value <= -9_223_372_036_854_775_808.0 {
            return Int.min
        }

        return Int(value.rounded(.towardZero))
    }

    /// `value.ToString("0.##########", CultureInfo.InvariantCulture)`. For custom formats .NET first
    /// rounds a double to 15 significant digits, then rounds those digits half up to 10 decimals.
    static func formatUpTo10Decimals(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        }

        if value.isInfinite {
            return value < 0 ? "-Infinity" : "Infinity"
        }

        let negative = value.sign == .minus
        if value == 0 {
            return negative ? "-0" : "0"
        }

        // "d.dddddddddddddde±x": 15 significant digits, correctly rounded.
        let scientific = String(format: "%.14e", abs(value))
        let parts = scientific.split(separator: "e")
        var digits = parts[0].compactMap { $0.wholeNumberValue }
        var scale = Int(parts[1])! + 1
        while digits.count > 1 && digits.last == 0 {
            digits.removeLast()
        }

        let keep = scale + 10
        if keep < digits.count {
            let roundUp = keep >= 0 && digits[keep] >= 5
            digits = keep > 0 ? Array(digits[0..<keep]) : []
            if roundUp {
                var i = digits.count - 1
                while i >= 0 && digits[i] == 9 {
                    digits[i] = 0
                    i -= 1
                }

                if i >= 0 {
                    digits[i] += 1
                } else {
                    digits.insert(1, at: 0)
                    scale += 1
                }
            }

            while digits.last == 0 {
                digits.removeLast()
            }
        }

        if digits.isEmpty {
            return negative ? "-0" : "0"
        }

        var integer = scale > 0
            ? digits.prefix(scale).map(String.init).joined() + String(repeating: "0", count: max(0, scale - digits.count))
            : "0"
        if integer.isEmpty {
            integer = "0"
        }

        let fraction = scale >= 0
            ? digits.dropFirst(scale).map(String.init).joined()
            : String(repeating: "0", count: -scale) + digits.map(String.init).joined()
        return (negative ? "-" : "") + integer + (fraction.isEmpty ? "" : "." + fraction)
    }
}
