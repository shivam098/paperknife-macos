/// One operation of a content stream: operands, operator, and the bytes it spans.
struct ContentOp {
    let `operator`: String

    let operands: [CosObject]

    let start: Int

    let end: Int

    init(_ name: String, _ operands: [CosObject], _ start: Int, _ end: Int) {
        self.`operator` = name
        self.operands = operands
        self.start = start
        self.end = end
    }
}

/// Splits decoded page content into operations (ISO 32000-1, 7.8.2).
enum ContentParser {
    /// The operations, or nil when the content can't be parsed with certainty.
    static func parse(_ data: [UInt8]) -> [ContentOp]? {
        let lexer = PdfLexer(data)
        var ops: [ContentOp] = []
        var operands: [CosObject] = []
        var start = -1
        while true {
            let token = lexer.next()
            if token.kind == .end {
                return ops
            }

            if token.kind == .keyword && token.text != "true" && token.text != "false" && token.text != "null" {
                var end = token.end
                if token.text == "BI" {
                    end = skipInlineImage(lexer)
                    if end < 0 {
                        return nil
                    }
                }

                ops.append(ContentOp(token.text, operands, start >= 0 ? start : token.start, end))
                operands.removeAll()
                start = -1
                continue
            }

            if start < 0 {
                start = token.start
            }

            guard let operand = PdfObjectParser.fromToken(lexer, token, allowReferences: false, 0) else {
                return nil
            }

            operands.append(operand)
        }
    }

    /// Moves past an inline image's dictionary, data and EI; returns the end offset, or -1.
    private static func skipInlineImage(_ lexer: PdfLexer) -> Int {
        let span = lexer.data
        var dict: [String: CosObject] = [:]
        while true {
            let token = lexer.next()
            if token.isKeyword("ID") {
                var data = token.end
                if data < span.count && PdfLexer.isWhitespace(span[data]) {
                    data += 1
                }

                if let length = unfilteredLength(dict), Int(length) <= span.count - data {
                    let end = PdfLexer(lexer.data, data + Int(length)).next()
                    if end.isKeyword("EI") {
                        lexer.position = end.end
                        return end.end
                    }
                }

                var i = data
                while i + 1 < span.count {
                    if span[i] == UInt8(ascii: "E") && span[i + 1] == UInt8(ascii: "I") && (i == data || PdfLexer.isWhitespace(span[i - 1]))
                        && (i + 2 == span.count || !PdfLexer.isRegular(span[i + 2])) {
                        lexer.position = i + 2
                        return i + 2
                    }

                    i += 1
                }

                return -1
            }

            guard token.kind == .name, let value = PdfObjectParser.fromToken(lexer, lexer.next(), allowReferences: false, 0) else {
                return -1
            }

            dict[token.text] = value
        }
    }

    /// The length of unfiltered image data, or nil when it isn't known.
    private static func unfilteredLength(_ dict: [String: CosObject]) -> Int32? {
        func get(_ shortKey: String, _ longKey: String) -> CosObject? { dict[shortKey] ?? dict[longKey] }

        func number(_ shortKey: String, _ longKey: String) -> Int32? {
            if let n = get(shortKey, longKey) as? CosNumber, n.value > 0 {
                return Int32(DotNetMath.toInt32(n.value))
            }

            return nil
        }

        if get("F", "Filter") != nil {
            return nil
        }

        let mask = (get("IM", "ImageMask") as? CosBool)?.value == true
        let components: Int32?
        if mask {
            components = 1
        } else {
            switch get("CS", "ColorSpace") {
            case let name as CosName where name.value == "G" || name.value == "DeviceGray" || name.value == "CalGray":
                components = 1
            case let name as CosName where name.value == "RGB" || name.value == "DeviceRGB" || name.value == "CalRGB":
                components = 3
            case let name as CosName where name.value == "CMYK" || name.value == "DeviceCMYK":
                components = 4
            case let array as CosArray where array.count > 0 && ((array.items[0] as? CosName).map { $0.value == "I" || $0.value == "Indexed" } ?? false):
                components = 1
            default:
                components = nil
            }
        }

        let bits = mask ? 1 : number("BPC", "BitsPerComponent")
        let width = number("W", "Width")
        let height = number("H", "Height")
        guard let c = components, let b = bits, let w = width, let h = height else {
            return nil
        }

        return size(c, b, w, h)
    }

    /// The size of an image's data, or nil when it doesn't fit in an Int32, as no content stream's
    /// can: C#'s `checked(height * (((width * components * bits) + 7) / 8))`, which throws at the
    /// first overflow.
    private static func size(_ components: Int32, _ bits: Int32, _ width: Int32, _ height: Int32) -> Int32? {
        let (samples, samplesOverflow) = width.multipliedReportingOverflow(by: components)
        let (rowBits, rowBitsOverflow) = samples.multipliedReportingOverflow(by: bits)
        let (padded, paddedOverflow) = rowBits.addingReportingOverflow(7)
        let (size, sizeOverflow) = height.multipliedReportingOverflow(by: padded / 8)
        return samplesOverflow || rowBitsOverflow || paddedOverflow || sizeOverflow ? nil : size
    }
}

/// An affine matrix [a b c d e f], mapping (x, y) to (a·x + c·y + e, b·x + d·y + f) as in PDF.
struct PdfMatrix: Equatable {
    let a: Double

    let b: Double

    let c: Double

    let d: Double

    let e: Double

    let f: Double

    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    static let identity = PdfMatrix(1, 0, 0, 1, 0, 0)

    static func translation(_ x: Double, _ y: Double) -> PdfMatrix { PdfMatrix(1, 0, 0, 1, x, y) }

    static func fromOperands(_ operands: [CosObject], _ start: Int = 0) -> PdfMatrix? {
        guard operands.count >= start + 6, operands[start..<(start + 6)].allSatisfy({ $0 is CosNumber }) else {
            return nil
        }

        func value(_ i: Int) -> Double { (operands[start + i] as! CosNumber).value }
        return PdfMatrix(value(0), value(1), value(2), value(3), value(4), value(5))
    }

    /// This transformation followed by `next`.
    func then(_ next: PdfMatrix) -> PdfMatrix {
        PdfMatrix(
            (a * next.a) + (b * next.c), (a * next.b) + (b * next.d),
            (c * next.a) + (d * next.c), (c * next.b) + (d * next.d),
            (e * next.a) + (f * next.c) + next.e, (e * next.b) + (f * next.d) + next.f)
    }

    func transform(_ x: Double, _ y: Double) -> (x: Double, y: Double) { ((a * x) + (c * y) + e, (b * x) + (d * y) + f) }

    func transformVector(_ x: Double, _ y: Double) -> (x: Double, y: Double) { ((a * x) + (c * y), (b * x) + (d * y)) }

    func invert() -> PdfMatrix? {
        let determinant = (a * d) - (b * c)
        return abs(determinant) < 1e-12
            ? nil
            : PdfMatrix(d / determinant, -b / determinant, -c / determinant, a / determinant,
                ((c * f) - (d * e)) / determinant, ((b * e) - (a * f)) / determinant)
    }

    func toOperands() -> String {
        "\(CosWriter.number(a)) \(CosWriter.number(b)) \(CosWriter.number(c)) \(CosWriter.number(d)) \(CosWriter.number(e)) \(CosWriter.number(f))"
    }

    /// A C# record struct's equality: each field by `double.Equals`, for which NaN equals NaN.
    static func == (x: PdfMatrix, y: PdfMatrix) -> Bool {
        func same(_ p: Double, _ q: Double) -> Bool { p == q || (p.isNaN && q.isNaN) }
        return same(x.a, y.a) && same(x.b, y.b) && same(x.c, y.c) && same(x.d, y.d) && same(x.e, y.e) && same(x.f, y.f)
    }
}
