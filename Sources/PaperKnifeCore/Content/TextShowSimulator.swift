/// A text-showing operation (Tj, TJ, ' or ") and the text state it runs in.
final class ShowOp {
    let opIndex: Int

    /// The BT/ET block it belongs to, or -1 outside one.
    let block: Int

    let ctm: PdfMatrix

    /// The matrix last set by Tm (or BT); positions are relative to it, as in PDFium.
    let textMatrix: PdfMatrix

    /// Where the operation starts in the text matrix's space, before any initial TJ adjustment.
    let x: Double

    let y: Double

    let positionKnown: Bool

    let fontName: String?

    let font: PdfFontInfo?

    let fontSize: Double

    let charSpace: Double

    let wordSpace: Double

    let horizontalScale: Double

    let rise: Double

    /// The TJ adjustment before the first string, in thousandths of an em.
    let initialKerning: Double

    /// The non-empty strings shown, each with the TJ adjustment that follows it.
    let segments: [(bytes: [UInt8], kerningAfter: Double)]

    /// Whether marked content around it replaces its text (/ActualText) or can't be checked.
    let inReplacedText: Bool

    /// The index of the text object PDFium creates for it, or -1 when it creates none.
    var ordinal = -1

    init(
        opIndex: Int, block: Int, ctm: PdfMatrix, textMatrix: PdfMatrix, x: Double, y: Double, positionKnown: Bool,
        fontName: String?, font: PdfFontInfo?, fontSize: Double, charSpace: Double, wordSpace: Double,
        horizontalScale: Double, rise: Double, initialKerning: Double, segments: [(bytes: [UInt8], kerningAfter: Double)],
        inReplacedText: Bool
    ) {
        self.opIndex = opIndex
        self.block = block
        self.ctm = ctm
        self.textMatrix = textMatrix
        self.x = x
        self.y = y
        self.positionKnown = positionKnown
        self.fontName = fontName
        self.font = font
        self.fontSize = fontSize
        self.charSpace = charSpace
        self.wordSpace = wordSpace
        self.horizontalScale = horizontalScale
        self.rise = rise
        self.initialKerning = initialKerning
        self.segments = segments
        self.inReplacedText = inReplacedText
    }

    var producesObject: Bool { ordinal >= 0 }

    /// Where the first glyph starts, after the initial TJ adjustment.
    var glyphX: Double { x - (initialKerning / 1000 * fontSize * horizontalScale) }

    /// The text matrix to set before repeating this operation unchanged.
    var opMatrix: PdfMatrix { PdfMatrix.translation(x, y).then(textMatrix) }

    /// The text matrix to set before showing new text in its place.
    var glyphMatrix: PdfMatrix { PdfMatrix.translation(glyphX, y).then(textMatrix) }

    /// The first glyph's origin in page space, where PDFium places the text object.
    var pageStart: (x: Double, y: Double) { textMatrix.then(ctm).transform(glyphX, y + rise) }

    /// The matrix PDFium reports for the text object, without its translation.
    var objectMatrix: PdfMatrix { PdfMatrix(horizontalScale, 0, 0, 1, 0, 0).then(textMatrix).then(ctm) }

    /// The codes shown, in order, each with the TJ adjustment that follows it (0 inside a string).
    func codes() -> [(code: UInt32, kerningAfter: Double)] {
        var codes: [(code: UInt32, kerningAfter: Double)] = []
        guard let font else {
            return codes
        }

        for (bytes, kerning) in segments {
            let split = font.splitCodes(bytes)
            for i in 0..<split.count {
                codes.append((split[i], i == split.count - 1 ? kerning : 0))
            }
        }

        return codes
    }
}

final class TextBlock {
    /// The index of the BT operation.
    let begin: Int

    /// The index of the ET operation, or -1 when the block isn't closed.
    var end = -1

    /// Whether it changes the graphics state in ways text blocks shouldn't (q, Q, cm).
    var irregular = false

    init(_ begin: Int) {
        self.begin = begin
    }
}

/// The text-showing operations of a page's content, as PDFium interprets them.
final class ContentTextLayout {
    let shows: [ShowOp]

    let blocks: [TextBlock]

    /// The operations that create text objects, in the order PDFium creates them.
    let objectShows: [ShowOp]

    init(shows: [ShowOp], blocks: [TextBlock], objectShows: [ShowOp]) {
        self.shows = shows
        self.blocks = blocks
        self.objectShows = objectShows
    }
}

/// Follows the graphics and text state through page content the way PDFium's content parser does
/// (core/fpdfapi/page/cpdf_streamcontentparser.cpp): which text-showing operations create text
/// objects, and where each starts. Advances need glyph widths; where a width is unknown, positions
/// that depend on it are marked unknown.
enum TextShowSimulator {
    static func run(
        _ ops: [ContentOp],
        _ file: PdfFile,
        _ resources: CosDict?,
        _ width: ((ShowOp, UInt32) -> Double?)? = nil
    ) throws -> ContentTextLayout {
        let width = width ?? { show, code in show.font?.width(code) }
        let fontResources = try file.resolveDict(resources?["Font"])
        let properties = try file.resolveDict(resources?["Properties"])
        var fonts: [String: PdfFontInfo?] = [:]
        var shows: [ShowOp] = []
        var objectShows: [ShowOp] = []
        var blocks: [TextBlock] = []
        var saved: [GraphicsState] = []
        var marks: [Bool] = []
        var state = GraphicsState()
        var textMatrix = PdfMatrix.identity

        // The start of the line in single precision, as PDFium keeps it (CFX_PointF), so text
        // rewritten with an explicit Tm (see ContentTextEdit) lands exactly where it was.
        var lineX: Float = 0
        var lineY: Float = 0
        var x: Double = 0
        var y: Double = 0
        var known = true
        var block = -1

        func markIrregular() {
            if block >= 0 {
                blocks[block].irregular = true
            }
        }

        func moveTo(_ tx: Double, _ ty: Double) {
            lineX += Float(tx)
            lineY += Float(ty)
            x = Double(lineX)
            y = Double(lineY)
            known = true
        }

        func nextLine() {
            lineY -= Float(state.leading)
            x = Double(lineX)
            y = Double(lineY)
            known = true
        }

        func fontInfo(_ name: String?) throws -> PdfFontInfo? {
            guard let name else {
                return nil
            }

            if let cached = fonts[name] {
                return cached
            }

            // Read once per font, however many names resources give it.
            let entry = fontResources?[name]
            func read() throws -> PdfFontInfo? {
                guard let dict = try file.resolveDict(entry) else {
                    return nil
                }

                return try PdfFontInfo.load(file, dict)
            }

            let info: PdfFontInfo?
            if let reference = entry as? CosRef {
                info = try file.derived("FontInfo", reference.number, read)
            } else {
                info = try read()
            }

            fonts.updateValue(info, forKey: name)
            return info
        }

        func show(_ index: Int, _ operand: CosObject, _ isArray: Bool) throws {
            if isArray && !(operand is CosArray) {
                return
            }

            var segments: [(bytes: [UInt8], kerningAfter: Double)] = []
            var initial: Double = 0
            var numbers: Double = 0
            var anyString = false
            let items = isArray ? (operand as! CosArray).items : [operand]
            for item in items {
                if let s = item as? CosString {
                    anyString = true
                    if !s.bytes.isEmpty {
                        segments.append((s.bytes, 0))
                    }
                } else if let n = item as? CosNumber, isArray {
                    numbers += n.value
                    if segments.isEmpty {
                        initial += n.value
                    } else {
                        segments[segments.count - 1].kerningAfter += n.value
                    }
                }
            }

            let font = try fontInfo(state.fontName)
            let operation = ShowOp(
                opIndex: index, block: block, ctm: state.ctm, textMatrix: textMatrix, x: x, y: y, positionKnown: known,
                fontName: state.fontName, font: font, fontSize: state.fontSize, charSpace: state.charSpace,
                wordSpace: state.wordSpace, horizontalScale: state.horizontalScale, rise: state.rise, initialKerning: initial,
                segments: segments, inReplacedText: marks.contains(true))
            shows.append(operation)
            if isArray && !anyString {
                // PDFium applies a TJ without strings as positioning only, with or without a font.
                x -= numbers / 1000 * state.fontSize * state.horizontalScale
                return
            }

            if state.fontName == nil {
                return
            }

            if !segments.isEmpty {
                operation.ordinal = objectShows.count
                objectShows.append(operation)
            }

            x -= initial / 1000 * state.fontSize * state.horizontalScale
            var advance: Double = 0
            for (code, kerning) in operation.codes() {
                guard let w = width(operation, code) else {
                    known = false
                    return
                }

                advance += (w * state.fontSize) + state.charSpace + (code == 32 && font!.codeLength == 1 ? state.wordSpace : 0)
                    - (kerning / 1000 * state.fontSize)
            }

            if font == nil && !segments.isEmpty {
                known = false
                return
            }

            x += advance * state.horizontalScale
        }

        for i in 0..<ops.count {
            let o = ops[i].operands
            switch ops[i].operator {
            case "q":
                saved.append(state)
                markIrregular()
            case "Q":
                if !saved.isEmpty {
                    state = saved.removeLast()
                }

                markIrregular()
            case "cm":
                if let m = PdfMatrix.fromOperands(o) {
                    state.ctm = m.then(state.ctm)
                }

                markIrregular()
            case "BT":
                block = blocks.count
                blocks.append(TextBlock(i))
                textMatrix = PdfMatrix.identity
                lineX = 0
                lineY = 0
                x = 0
                y = 0
                known = true
            case "ET":
                if block >= 0 {
                    blocks[block].end = i
                }

                block = -1
            case "Tf":
                if o.count == 2, let name = o[0] as? CosName, let size = o[1] as? CosNumber {
                    state.fontName = name.value
                    state.fontSize = size.value
                }
            case "Tc":
                if let value = number(o, 0) {
                    state.charSpace = value
                }
            case "Tw":
                if let value = number(o, 0) {
                    state.wordSpace = value
                }
            case "Tz":
                if o.count == 1, let value = number(o, 0) {
                    state.horizontalScale = value / 100
                }
            case "TL":
                if let value = number(o, 0) {
                    state.leading = value
                }
            case "Ts":
                if let value = number(o, 0) {
                    state.rise = value
                }
            case "Tm":
                if let matrix = PdfMatrix.fromOperands(o) {
                    textMatrix = matrix
                    lineX = 0
                    lineY = 0
                    x = 0
                    y = 0
                    known = true
                }
            case "Td":
                if let tx = number(o, 0), let ty = number(o, 1) {
                    moveTo(tx, ty)
                }
            case "TD":
                if let tx = number(o, 0), let ty = number(o, 1) {
                    state.leading = -ty
                    moveTo(tx, ty)
                }
            case "T*":
                nextLine()
            case "'":
                if o.count >= 1 {
                    nextLine()
                    try show(i, o[o.count - 1], false)
                }
            case "\"":
                if o.count >= 3, let aw = number(o, 0), let ac = number(o, 1) {
                    state.wordSpace = aw
                    state.charSpace = ac
                    nextLine()
                    try show(i, o[2], false)
                }
            case "Tj":
                if o.count >= 1 {
                    try show(i, o[o.count - 1], false)
                }
            case "TJ":
                if o.count >= 1 {
                    try show(i, o[o.count - 1], true)
                }
            case "BDC":
                var replaced = true
                if o.count >= 2 {
                    if let dict = o[1] as? CosDict {
                        replaced = dict["ActualText"] != nil
                    } else if let propertyName = o[1] as? CosName {
                        if let props = try file.resolveDict(properties?[propertyName.value]) {
                            replaced = props["ActualText"] != nil
                        }
                    }
                }

                marks.append(replaced)
            case "BMC":
                marks.append(false)
            case "EMC":
                if !marks.isEmpty {
                    marks.removeLast()
                }
            default:
                break
            }
        }

        return ContentTextLayout(shows: shows, blocks: blocks, objectShows: objectShows)
    }

    private static func number(_ operands: [CosObject], _ index: Int) -> Double? {
        index < operands.count ? (operands[index] as? CosNumber)?.value : nil
    }

    private struct GraphicsState {
        var ctm = PdfMatrix.identity

        var fontName: String?

        var fontSize: Double = 0

        var charSpace: Double = 0

        var wordSpace: Double = 0

        var horizontalScale: Double = 1

        var leading: Double = 0

        var rise: Double = 0
    }
}
