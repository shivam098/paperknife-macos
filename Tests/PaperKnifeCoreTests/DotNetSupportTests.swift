import XCTest
@testable import PaperKnifeCore

/// The .NET semantics the port relies on. Expected values were computed with .NET 10, the runtime
/// of PaperKnife for Windows; doubles are given by their bits.
final class DotNetSupportTests: XCTestCase {
    func testNumbersAreFormattedAsCosWriterFormatsThem() {
        // (bits of the value, Math.Round(value, 10).ToString("0.##########") with "-0" as "0")
        let cases: [(Int64, String)] = [
            (0, "0"),
            (-9223372036854775808, "0"),
            (4607182418800017408, "1"),
            (-4616189618054758400, "-1"),
            (4602678819172646912, "0.5"),
            (4634766966517661696, "72"),
            (4645611352945393140, "392.432"),
            (4639296148043988992, "144.7270812988"),
            (4640296369691557888, "173.155090332"),
            (4442235333156365461, "0"),
            (4452789957460213179, "0"),
            (4452789957461760604, "0.0000000001"),
            (4742964961033578167, "1234567890.12346"),
            (4817745636528479851, "123456789012346"),
            (4831355200913801216, "1000000000000000"),
            (4846369599423283195, "9999999999999990"),
            (4846369599423283200, "10000000000000000"),
            (4847542438873900484, "12345678901234600"),
            (4906019910204099648, "100000000000000000000"),
            (-4317352126650676160, "-100000000000000000000"),
            (4607182418800017409, "1"),
            (4599075939470750516, "0.3"),
            (-4600232419437613253, "-12.3456789012"),
            (4741671816366391296, "1000000000"),
            (4613205983301625446, "2.675"),
            (4607184670599831093, "1.0005"),
            (4614256656552045848, "3.1415926536"),
            (4599676419421066581, "0.3333333333"),
            (4604180019048437077, "0.6666666667"),
            (-4619192017806338731, "-0.6666666667"),
            (4636737291354639806, "100"),
            (4544867299706393481, "0.000071"),
            (4548686775598975835, "0.0001234568"),
            (118622047889322841, "0"),
            (-9104749988965452967, "0"),
            (4629888066921343654, "33.3333333333"),
            (4648098325102120141, "555.6"),
            (4602678819172646910, "0.5"),
            (4668012723080811475, "12345.6789012346"),
            (4539760997215258826, "0.0000314159"),
        ]
        for (bits, expected) in cases {
            let value = Double(bitPattern: UInt64(bitPattern: bits))
            let text = DotNetMath.formatUpTo10Decimals(DotNetMath.round(value, 10))
            XCTAssertEqual(text == "-0" ? "0" : text, expected, "\(value)")
        }
    }

    func testRoundingMatchesMathRound() {
        // (value, Math.Round(v), Math.Round(v, AwayFromZero), Math.Round(v, 2), Math.Round(v, 2, AwayFromZero)), as bits
        let cases: [(Int64, Int64, Int64, Int64, Int64)] = [
            (4602678819172646912, 0, 4607182418800017408, 4602678819172646912, 4602678819172646912),
            (4609434218613702656, 4611686018427387904, 4611686018427387904, 4609434218613702656, 4609434218613702656),
            (4612811918334230528, 4611686018427387904, 4613937818241073152, 4612811918334230528, 4612811918334230528),
            (-4620693217682128896, -9223372036854775808, -4616189618054758400, -4620693217682128896, -4620693217682128896),
            (-4613937818241073152, -4611686018427387904, -4611686018427387904, -4613937818241073152, -4613937818241073152),
            (-4610560118520545280, -4611686018427387904, -4609434218613702656, -4610560118520545280, -4610560118520545280),
            (4602678819172646911, 0, 0, 4602678819172646912, 4602678819172646912),
            (4613205983301625446, 4613937818241073152, 4613937818241073152, 4613217242300693873, 4613217242300693873),
            (4607204936798154260, 4607182418800017408, 4607182418800017408, 4607182418800017408, 4607182418800017408),
            (-4616167100056621548, -4616189618054758400, -4616189618054758400, -4616189618054758400, -4616189618054758400),
            (4653144502051863213, 4653146402887565312, 4653146402887565312, 4653144511727565537, 4653144511727565537),
            (4593671619917905920, 0, 0, 4593311331947716280, 4593851763903000740),
            (4600427019358961664, 0, 0, 4600517091351509074, 4600517091351509074),
            (4861130398305394688, 4861130398305394688, 4861130398305394688, 4861130398305394688, 4861130398305394688),
            (-2251799813685248, -2251799813685248, -2251799813685248, -2251799813685248, -2251799813685248),
            (9218868437227405312, 9218868437227405312, 9218868437227405312, 9218868437227405312, 9218868437227405312),
        ]
        func bits(_ value: Double) -> Int64 { Int64(bitPattern: value.bitPattern) }
        for (input, toEven, awayFromZero, twoDigits, twoDigitsAway) in cases {
            let value = Double(bitPattern: UInt64(bitPattern: input))
            XCTAssertEqual(bits(DotNetMath.round(value)), toEven, "\(value)")
            XCTAssertEqual(bits(DotNetMath.roundAwayFromZero(value)), awayFromZero, "\(value)")
            XCTAssertEqual(bits(DotNetMath.round(value, 2)), twoDigits, "\(value)")
            XCTAssertEqual(bits(DotNetMath.round(value, 2, awayFromZero: true)), twoDigitsAway, "\(value)")
        }
    }

    func testCastsSaturateAsInDotNet() {
        // (value as bits, (int)v, (long)v, (int)(float)v)
        let cases: [(Int64, Int, Int, Int)] = [
            (4615964438073389875, 3, 3, 3),
            (-4607407598781385933, -3, -3, -3),
            (4602678819172646912, 0, 0, 0),
            (-4620693217682128896, 0, 0, 0),
            (4746794007246405632, 2147483647, 2147483647, 2147483647),
            (4746794007248502784, 2147483647, 2147483648, 2147483647),
            (-4476578029604175872, -2147483648, -2147483649, -2147483648),
            (4756540486875873280, 2147483647, 10000000000, 2147483647),
            (-4466831549978902528, -2147483648, -10000000000, -2147483648),
            (-2251799813685248, 0, 0, 0),
            (9218868437227405312, 2147483647, 9223372036854775807, 2147483647),
            (-4503599627370496, -2147483648, -9223372036854775808, -2147483648),
        ]
        for (input, int32, int64, fromFloat) in cases {
            let value = Double(bitPattern: UInt64(bitPattern: input))
            XCTAssertEqual(DotNetMath.toInt32(value), int32, "\(value)")
            XCTAssertEqual(DotNetMath.toInt64(value), int64, "\(value)")
            XCTAssertEqual(DotNetMath.toInt32(Float(value)), fromFloat, "\(value)")
        }
    }

    func testStringsCompareByCodeUnits() {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        XCTAssertTrue(precomposed == decomposed, "Swift compares canonically.")
        XCTAssertFalse(precomposed.ordinalEquals(decomposed))
        XCTAssertNotEqual(OrdinalString(precomposed), OrdinalString(decomposed))
        XCTAssertTrue(decomposed.ordinalHasPrefix("e"))
        XCTAssertEqual("a\u{1F600}b".length, 4)
        XCTAssertEqual("x\u{301}y".ordinalIndexOf("\u{301}"), 1)
        XCTAssertTrue(String.ordinalLess("Z", "a"))
        XCTAssertTrue(String.ordinalLess("\u{1F600}", "\u{FF5E}"), "By code unit, a surrogate (D83D) comes before U+FF5E.")
        XCTAssertEqual("a,,b".split(onUnit: 0x2C), ["a", "", "b"])
        XCTAssertEqual(" \u{A0}text\u{2003}\u{85}".dotNetTrim(), "text")
        XCTAssertEqual("AbcAbc".ordinalReplacing("bc", with: "x"), "AxAx")
        XCTAssertEqual("hello".substring(1, 3), "ell")
    }

    func testCharactersAreClassifiedAsInDotNet() {
        XCTAssertTrue(DotNetChar.isWhiteSpace(0x85))
        XCTAssertTrue(DotNetChar.isWhiteSpace(0x3000))
        XCTAssertFalse(DotNetChar.isWhiteSpace(0x200B))
        XCTAssertTrue(DotNetChar.isControl(0x7F))
        XCTAssertEqual(DotNetChar.category(0xD83D), .surrogate)
        XCTAssertEqual(DotNetChar.category(0x0301), .nonSpacingMark)
        XCTAssertEqual(DotNetChar.category(0x2028), .lineSeparator)
        XCTAssertEqual(DotNetChar.category(0x00AD), .format)
        XCTAssertTrue(DotNetChar.isSurrogatePair("a\u{1F600}".units, 1))
        XCTAssertEqual(DotNetChar.convertFromUtf32(0x1F600), "\u{1F600}")
        XCTAssertNil(DotNetChar.convertFromUtf32(0xD800))
    }

    func testIntegersParseAsInDotNet() {
        XCTAssertEqual(DotNetParse.hexInt32("00E9".units), 0xE9)
        XCTAssertNil(DotNetParse.hexInt32("-123".units))
        XCTAssertNil(DotNetParse.hexInt32("".units))
        XCTAssertEqual(DotNetParse.hexInt32("FFFFFFFF".units), -1)
        XCTAssertNil(DotNetParse.hexInt32("100000000".units))
        XCTAssertEqual(DotNetParse.int32(" -42 "), -42)
        XCTAssertEqual(DotNetParse.int32("+7"), 7)
        XCTAssertNil(DotNetParse.int32("2147483648"))
        XCTAssertEqual(DotNetParse.int32("-2147483648"), Int(Int32.min))
        XCTAssertNil(DotNetParse.int32("1.5"))
    }

    func testOrderedDictionaryReusesFreedPlacesAsCSharpDoes() {
        var dictionary = OrderedDictionary<String, Int>()
        dictionary["a"] = 1
        dictionary["b"] = 2
        dictionary["c"] = 3
        dictionary["b"] = nil
        dictionary["d"] = 4
        dictionary["a"] = 5
        XCTAssertEqual(dictionary.keys, ["a", "d", "c"])
        XCTAssertEqual(dictionary.values, [5, 4, 3])
        XCTAssertFalse(dictionary.tryAdd("a", 9))
        XCTAssertEqual(Array([3, 1, 2, 1, 3].distinctInOrder()), [3, 1, 2])
        let pairs = [(1, "x"), (0, "y"), (1, "z"), (0, "w")]
        XCTAssertEqual(pairs.stableSorted { $0.0 < $1.0 }.map(\.1), ["y", "w", "x", "z"])
    }
}
