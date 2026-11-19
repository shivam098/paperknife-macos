import CPDFium

/// What PDFium's text extraction put between two characters that follow each other.
enum TextGap {
    case none
    case space
    case lineBreak
}

/// One top-level text object, as `TextLayout` sees it.
final class TextPiece {
    init(_ objectIndex: Int, _ handle: FPDF_PAGEOBJECT) {
        self.objectIndex = objectIndex
        self.handle = handle
    }

    let objectIndex: Int

    let handle: FPDF_PAGEOBJECT

    /// The object's own characters in reading order, plus the spaces PDFium found between them
    /// (for example for a large kerning adjustment), but not the gap after the last one.
    var text = ""

    /// False when a character has no Unicode value, or the object's characters aren't contiguous in
    /// reading order. Such objects still form a run of their own, but never join other objects.
    var isWellFormed = true

    var firstCharacter = -1

    var lastCharacter = -1

    var lastUnicode: UInt32 = 0

    /// Origins of the first and last character, in page space.
    var firstOrigin: (x: Double, y: Double) = (0, 0)

    var lastOrigin: (x: Double, y: Double) = (0, 0)

    /// Advance width of the last character, in text space units.
    var lastAdvance: Float = 0

    /// False when `lastAdvance` may be wrong: the font's width for the last character's Unicode
    /// value disagrees with the boxes PDFium measured for the glyph that was drawn. Then nothing
    /// after this object can be moved to fit an edit that ends here.
    var isEndKnown = true

    /// PDFium's tight box (the glyph's ink) and loose box of the last character, in page space.
    var lastInkBox: PdfRect?

    var lastLooseBox: PdfRect?

    /// Where the last character's advance ends, in page space.
    var end: (x: Double, y: Double) {
        (lastOrigin.x + Double(lastAdvance * matrix.a), lastOrigin.y + Double(lastAdvance * matrix.b))
    }

    /// The object whose characters come right after this one's in reading order, and what lies between them.
    var next: TextPiece?

    var gapAfter = TextGap.none

    /// Maps text space (without the font size) to page space; the translation is the object's origin.
    var matrix = FsMatrix()

    var hasMatrix = false

    var fontSize: Float = 0

    var font: FPDF_FONT?

    /// The font's name as PDFium reports it: /BaseFont, without the subset tag for embedded fonts.
    var fontName = ""

    var isEmbedded = false

    var renderMode = 0

    var bounds: PdfRect?

    var clipSignature: [Float]?

    var hasCharacters: Bool { firstCharacter >= 0 }
}

/// A run and the text objects it is made of, valid until the page changes.
final class TextRunLayout {
    init(_ run: PdfTextRun, _ pieces: [TextPiece], _ separators: [String], _ fullText: String) {
        self.run = run
        self.pieces = pieces
        self.separators = separators
        self.fullText = fullText
    }

    let run: PdfTextRun

    let pieces: [TextPiece]

    /// `separators[i]` is the text between `pieces[i]` and `pieces[i + 1]`: a space PDFium found in the gap, or nothing.
    let separators: [String]

    /// The run's text including trailing whitespace, which `PdfTextRun.text` leaves out.
    let fullText: String

    func contains(_ objectIndex: Int) -> Bool {
        objectIndex >= run.objectIndex && objectIndex < run.objectIndex + run.objectCount
    }

    /// Distance along the run's baseline from the first object's origin to a page-space point, in text space units.
    func distanceAlongBaseline(_ x: Double, _ y: Double) -> Double {
        let first = pieces[0]
        return TextLayout.toTextSpace(first.matrix, x - Double(first.matrix.e), y - Double(first.matrix.f)).u
    }

    /// Where the last character of a piece ends, along the run's baseline.
    func endAlongBaseline(_ piece: TextPiece) -> Double {
        distanceAlongBaseline(piece.lastOrigin.x, piece.lastOrigin.y) + Double(piece.lastAdvance)
    }
}

/// Groups a page's top-level text objects into the runs PaperKnife edits. Many PDFs draw a line
/// with one text object, but some draw every character as its own object (for example PDFs made
/// from web pages with wkhtmltopdf), or every word. Consecutive objects join a run when they
/// follow each other in reading order on the same baseline, close together, and look the same:
/// same font, size, orientation, colors, render mode, clipping and marked content. Use only while
/// holding `PdfiumLibrary`'s lock; the result is valid until the page changes.
enum TextLayout {
    // Limits for joining two objects, in ems of the font size. Gaps between table cells are
    // usually wider than maxGap; gaps between words are narrower.
    private static let maxBaselineShift = 0.05
    private static let maxGap = 1.0
    private static let maxOverlap = 0.5
    private static let relativeTolerance = 1e-4

    static func build(_ page: FPDF_PAGE, _ pageIndex: Int) -> (pieces: [TextPiece], runs: [TextRunLayout]) {
        var pieces: [TextPiece] = []
        var byHandle: [FPDF_PAGEOBJECT: TextPiece] = [:]
        let count = Int(FPDFPage_CountObjects(page))
        var i = 0
        while i < count {
            if let obj = FPDFPage_GetObject(page, Int32(i)), FPDFPageObj_GetType(obj) == FPDF_PAGEOBJ_TEXT {
                let piece = TextPiece(i, obj)
                pieces.append(piece)
                byHandle[obj] = piece
            }

            i += 1
        }

        if pieces.isEmpty {
            return (pieces, [])
        }

        if let textPage = FPDFText_LoadPage(page) {
            defer { FPDFText_ClosePage(textPage) }
            readCharacters(textPage, byHandle)
        }

        for piece in pieces {
            readGeometry(piece)
        }

        var runs: [TextRunLayout] = []
        var next = 0
        while next < pieces.count {
            var current = [pieces[next]]
            next += 1
            var separators: [String] = []
            while next < pieces.count {
                var separator = ""
                if tryJoin(current[current.count - 1], pieces[next], &separator) {
                    separators.append(separator)
                    current.append(pieces[next])
                    next += 1
                    continue
                }

                // Spaces drawn as objects of their own sit between the words they separate.
                var end = next
                while end < pieces.count && isSpacer(pieces[end]) && pieces[end].objectIndex == pieces[end - 1].objectIndex + 1 {
                    end += 1
                }

                if end == next || end == pieces.count || !tryJoinAcrossSpacers(current[current.count - 1], pieces, next, end) {
                    break
                }

                while next <= end {
                    separators.append("")
                    current.append(pieces[next])
                    next += 1
                }
            }

            runs.append(createRun(pageIndex, current, separators))
        }

        return (pieces, runs)
    }

    /// Maps a page-space displacement into a text space: along the baseline (u) and across it (v).
    static func toTextSpace(_ m: FsMatrix, _ dx: Double, _ dy: Double) -> (u: Double, v: Double) {
        let determinant = (Double(m.a) * Double(m.d)) - (Double(m.b) * Double(m.c))
        if abs(determinant) < 1e-12 {
            return (.nan, .nan)
        }

        return (((Double(m.d) * dx) - (Double(m.c) * dy)) / determinant, ((Double(m.a) * dy) - (Double(m.b) * dx)) / determinant)
    }

    /// The advance width of `text` set with `font`, in text space units, as PDFium lays it out.
    static func measure(_ font: FPDF_FONT?, _ fontSize: Float, _ text: String) -> Double {
        var total = 0.0
        for c in text.utf16 {
            var width: Float = 0
            if FPDFFont_GetGlyphWidth(font, UInt32(c), fontSize, &width) != 0 {
                total += Double(width)
            }
        }

        return total
    }

    private static func readCharacters(_ textPage: FPDF_TEXTPAGE, _ pieces: [FPDF_PAGEOBJECT: TextPiece]) {
        // The characters of each piece, in the order the pieces are first met, as C#'s Dictionary enumerates them.
        var texts: [ObjectIdentifier: [UInt16]] = [:]
        var order: [TextPiece] = []
        let count = Int(FPDFText_CountChars(textPage))
        var previous: TextPiece?
        var gap = TextGap.none
        var i = 0
        while i < count {
            defer { i += 1 }
            let unicode = FPDFText_GetUnicode(textPage, Int32(i))
            if FPDFText_IsGenerated(textPage, Int32(i)) == 1 {
                gap = unicode == 0x0D || unicode == 0x0A || gap == .lineBreak ? .lineBreak : .space
                continue
            }

            guard let handle = FPDFText_GetTextObject(textPage, Int32(i)), let piece = pieces[handle] else {
                // Text inside a form XObject isn't editable; it separates the text around it.
                previous = nil
                gap = TextGap.none
                continue
            }

            let id = ObjectIdentifier(piece)
            if texts[id] == nil {
                texts[id] = []
                order.append(piece)
                piece.firstCharacter = i
                if let previous {
                    previous.next = piece
                    previous.gapAfter = gap
                }
            } else if piece !== previous || gap == .lineBreak {
                // The object's characters resume after another object's, or on another line.
                piece.isWellFormed = false
            }

            if piece === previous && gap != TextGap.none {
                texts[id]!.append(0x20)
            }

            if unicode == 0 || unicode > 0x10FFFF {
                piece.isWellFormed = false
            } else if unicode <= 0xFFFF {
                // On Windows PDFium reports characters outside the BMP as two UTF-16 surrogates.
                texts[id]!.append(UInt16(unicode))
            } else {
                let value = unicode - 0x10000
                texts[id]!.append(UInt16(0xD800 + (value >> 10)))
                texts[id]!.append(UInt16(0xDC00 + (value & 0x3FF)))
            }

            piece.lastCharacter = i
            piece.lastUnicode = unicode
            previous = piece
            gap = TextGap.none
        }

        for piece in order {
            piece.text = String(units: texts[ObjectIdentifier(piece)]!)
            var x = 0.0
            var y = 0.0
            if FPDFText_GetCharOrigin(textPage, Int32(piece.firstCharacter), &x, &y) != 0 {
                piece.firstOrigin = (x, y)
            }

            if FPDFText_GetCharOrigin(textPage, Int32(piece.lastCharacter), &x, &y) != 0 {
                piece.lastOrigin = (x, y)
            }

            var left = 0.0
            var right = 0.0
            var bottom = 0.0
            var top = 0.0
            if FPDFText_GetCharBox(textPage, Int32(piece.lastCharacter), &left, &right, &bottom, &top) != 0 {
                piece.lastInkBox = PdfRect(Float(left), Float(bottom), Float(right), Float(top))
            }

            var loose = FsRectF()
            if FPDFText_GetLooseCharBox(textPage, Int32(piece.lastCharacter), &loose) != 0 {
                piece.lastLooseBox = PdfRect(loose.left, loose.bottom, loose.right, loose.top)
            }
        }
    }

    private static func readGeometry(_ piece: TextPiece) {
        let handle = piece.handle
        var matrix = FsMatrix()
        piece.hasMatrix = FPDFPageObj_GetMatrix(handle, &matrix) != 0
        piece.matrix = piece.hasMatrix ? matrix : FsMatrix()

        var size: Float = 0
        FPDFTextObj_GetFontSize(handle, &size)
        piece.fontSize = size
        piece.font = FPDFTextObj_GetFont(handle)
        piece.fontName = piece.font.map(rawFontName) ?? ""
        piece.isEmbedded = piece.font != nil && FPDFFont_GetIsEmbedded(piece.font) == 1
        piece.renderMode = Int(FPDFTextObj_GetTextRenderMode(handle).rawValue)

        var left: Float = 0
        var bottom: Float = 0
        var right: Float = 0
        var top: Float = 0
        if FPDFPageObj_GetBounds(handle, &left, &bottom, &right, &top) != 0 {
            piece.bounds = PdfRect(left, bottom, right, top)
        }

        if piece.hasCharacters && piece.font != nil {
            measureLastAdvance(piece)
        }
    }

    /// Sets the advance width of a piece's last character. The font gives a width by Unicode
    /// value, which PDFium maps back to a character code; for ligatures, alternate glyphs and some
    /// encodings that isn't the code that was drawn. PDFium's loose box of a character is its
    /// advance box, from the code that was drawn, united with its ink; a space's ink box is its
    /// advance box. So where the boxes show the advance, it is exact. Otherwise the advance ends
    /// within the ink, and the font's width must agree with that.
    private static func measureLastAdvance(_ piece: TextPiece) {
        var width: Float = 0
        let hasWidth = piece.lastUnicode <= 0xFFFF
            && FPDFFont_GetGlyphWidth(piece.font, piece.lastUnicode, piece.fontSize, &width) != 0
        piece.lastAdvance = width
        guard piece.hasMatrix, isAxisAligned(piece.matrix), let ink = piece.lastInkBox, let loose = piece.lastLooseBox else {
            return
        }

        let (inkStart, inkEnd, inkDepth) = extentAlongBaseline(piece, ink)
        let (_, looseEnd, _) = extentAlongBaseline(piece, loose)
        if inkEnd.isNaN || looseEnd.isNaN {
            return
        }

        let tolerance = Double(piece.fontSize) * 1e-3
        let isSpace = inkDepth < Double(piece.fontSize) * 0.01 && abs(inkStart) < tolerance

        // The union copies one box's edge, so the ends differ only where the advance box sticks out.
        if looseEnd > inkEnd || isSpace {
            piece.lastAdvance = Float(looseEnd)
            return
        }

        piece.isEndKnown = hasWidth && Double(width) > inkStart + tolerance && Double(width) <= inkEnd + tolerance
    }

    /// Whether text with this matrix runs along the page's x or y axis, so its boxes are exact.
    private static func isAxisAligned(_ m: FsMatrix) -> Bool {
        let scale = DotNetMath.maximum(DotNetMath.maximum(abs(m.a), abs(m.b)), DotNetMath.maximum(abs(m.c), abs(m.d)))
        let tolerance = Double(scale) * relativeTolerance
        return (Double(abs(m.b)) <= tolerance && Double(abs(m.c)) <= tolerance)
            || (Double(abs(m.a)) <= tolerance && Double(abs(m.d)) <= tolerance)
    }

    /// Where a page-space box starts and ends along a piece's baseline, measured from its last
    /// character's origin, and how deep it is across the baseline, in text space units.
    private static func extentAlongBaseline(_ piece: TextPiece, _ box: PdfRect) -> (start: Double, end: Double, depth: Double) {
        var minU = Double.greatestFiniteMagnitude
        var maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
        let corners: [(x: Float, y: Float)] = [(box.left, box.bottom), (box.left, box.top), (box.right, box.bottom), (box.right, box.top)]
        for (x, y) in corners {
            let (u, v) = toTextSpace(piece.matrix, Double(x) - piece.lastOrigin.x, Double(y) - piece.lastOrigin.y)
            if u.isNaN {
                return (.nan, .nan, .nan)
            }

            (minU, maxU, minV, maxV) = (
                DotNetMath.minimum(minU, u), DotNetMath.maximum(maxU, u), DotNetMath.minimum(minV, v), DotNetMath.maximum(maxV, v)
            )
        }

        return (minU, maxU, maxV - minV)
    }

    private static func tryJoin(_ previous: TextPiece, _ next: TextPiece, _ separator: inout String) -> Bool {
        separator = ""
        if next.objectIndex != previous.objectIndex + 1 || !canJoin(previous, next) {
            return false
        }

        let size = Double(previous.fontSize)
        guard let value = gapAlongBaseline(previous, previous.end, next.firstOrigin), !(value > maxGap * size), !(value < -maxOverlap * size) else {
            return false
        }

        // A line break PDFium reports between characters on one baseline is a misjudged
        // direction (common for lines of one-character objects); the gap decides instead.
        let space = previous.gapAfter == .space
            || (previous.gapAfter == .lineBreak && value >= Double(spaceWidth(previous) / 2))
        if space && !DotNetChar.isWhiteSpace(previous.text.units[previous.text.length - 1])
            && !DotNetChar.isWhiteSpace(next.text.units[0]) {
            separator = " "
        }

        return true
    }

    /// A text object with no characters in PDFium's text extraction and a bounding box of zero
    /// size. PDFium skips objects that draw only spaces (and reports the gap as a generated space),
    /// so these are usually spaces, sometimes empty strings.
    private static func isSpacer(_ piece: TextPiece) -> Bool {
        guard !piece.hasCharacters, piece.font != nil, piece.hasMatrix, let b = piece.bounds else {
            return false
        }

        return b.width < 0.01 && b.height < 0.01
    }

    /// Joins `previous`, the spacers `pieces[first..<end]` and the text object `pieces[end]` when
    /// the spacers sit on the line between them. Each spacer that leaves a gap of at least half a
    /// space becomes a space in the run's text.
    private static func tryJoinAcrossSpacers(_ previous: TextPiece, _ pieces: [TextPiece], _ first: Int, _ end: Int) -> Bool {
        let next = pieces[end]
        if next.objectIndex != pieces[end - 1].objectIndex + 1 || !canJoin(previous, next) {
            return false
        }

        let size = Double(previous.fontSize)
        var position = previous.end
        var starts: [Double] = []
        for i in first...end {
            let piece = pieces[i]
            let origin: (x: Double, y: Double) = i < end ? (Double(piece.matrix.e), Double(piece.matrix.f)) : piece.firstOrigin
            guard let value = gapAlongBaseline(previous, position, origin), !(value < (i == first ? -maxOverlap * size : 0)),
                !(value > maxGap * size), !(i < end && !sameStyle(previous, piece))
            else {
                return false
            }

            position = origin
            starts.append(toTextSpace(previous.matrix, origin.x - previous.lastOrigin.x, origin.y - previous.lastOrigin.y).u)
        }

        let normalSpace = spaceWidth(previous)
        for i in first..<end {
            // PDFium doesn't measure spacers: take a normal space, but no wider than the gap it leaves.
            let spacer = pieces[i]
            let gap = starts[i - first + 1] - starts[i - first]
            let isSpace = gap >= Double(normalSpace / 2)
            spacer.text = isSpace ? " " : ""
            spacer.firstOrigin = (Double(spacer.matrix.e), Double(spacer.matrix.f))
            spacer.lastOrigin = spacer.firstOrigin
            spacer.lastAdvance = isSpace ? Float(DotNetMath.minimum(Double(normalSpace), gap)) : 0
        }

        return true
    }

    /// The width of a space in a piece's font and size, in text space units.
    private static func spaceWidth(_ piece: TextPiece) -> Float {
        var width: Float = 0
        FPDFFont_GetGlyphWidth(piece.font, 0x20, piece.fontSize, &width)
        return width > 0 ? width : piece.fontSize / 4
    }

    /// Whether two text objects with characters can be in one run, apart from where they are.
    private static func canJoin(_ previous: TextPiece, _ next: TextPiece) -> Bool {
        previous.isWellFormed && next.isWellFormed && previous.hasCharacters && next.hasCharacters
            && previous.next === next && sameStyle(previous, next)
    }

    private static func sameStyle(_ a: TextPiece, _ b: TextPiece) -> Bool {
        a.font != nil && (a.font == b.font || sameTypeface(a, b)) && a.renderMode == b.renderMode
            && a.fontSize > 0 && Double(abs(a.fontSize - b.fontSize)) <= Double(a.fontSize) * 1e-3
            && a.hasMatrix && b.hasMatrix && sameOrientation(a.matrix, b.matrix)
            && sameColors(a, b) && sameMarks(a, b) && sameClip(a, b)
    }

    /// Whether two embedded fonts have the same name, as two subsets of one font do, and the complete
    /// copy PaperKnife adds for new letters and the font it copies (PDFium reports names without
    /// subset tags). Text in them belongs together.
    private static func sameTypeface(_ a: TextPiece, _ b: TextPiece) -> Bool {
        a.isEmbedded && b.isEmbedded && b.font != nil && a.fontName.length > 0 && a.fontName.ordinalEquals(b.fontName)
    }

    /// How far `to` lies beyond `from` along the baseline of `piece`, in text space units; nil when
    /// it isn't on that baseline.
    private static func gapAlongBaseline(_ piece: TextPiece, _ from: (x: Double, y: Double), _ to: (x: Double, y: Double)) -> Double? {
        let (fromU, fromV) = toTextSpace(piece.matrix, from.x - piece.lastOrigin.x, from.y - piece.lastOrigin.y)
        let (toU, toV) = toTextSpace(piece.matrix, to.x - piece.lastOrigin.x, to.y - piece.lastOrigin.y)
        if toU.isNaN || abs(toV - fromV) > maxBaselineShift * Double(piece.fontSize) {
            return nil
        }

        return toU - fromU
    }

    private static func sameOrientation(_ a: FsMatrix, _ b: FsMatrix) -> Bool {
        let scale = DotNetMath.maximum(DotNetMath.maximum(abs(a.a), abs(a.b)), DotNetMath.maximum(abs(a.c), abs(a.d)))
        let tolerance = Double(scale) * relativeTolerance
        return Double(abs(a.a - b.a)) <= tolerance && Double(abs(a.b - b.b)) <= tolerance
            && Double(abs(a.c - b.c)) <= tolerance && Double(abs(a.d - b.d)) <= tolerance
    }

    private static func sameColors(_ a: TextPiece, _ b: TextPiece) -> Bool {
        guard let fillA = tryGetColor(a.handle, stroke: false), let fillB = tryGetColor(b.handle, stroke: false), fillA == fillB else {
            return false
        }

        // Render modes 1, 2, 5 and 6 stroke the glyph outlines.
        if [1, 2, 5, 6].contains(a.renderMode) {
            guard let strokeA = tryGetColor(a.handle, stroke: true), let strokeB = tryGetColor(b.handle, stroke: true) else {
                return false
            }

            return strokeA == strokeB
        }

        return true
    }

    /// The object's fill or stroke color, or nil where C#'s `TryGetColor` returns false.
    private static func tryGetColor(_ handle: FPDF_PAGEOBJECT, stroke: Bool) -> [UInt32]? {
        var r: UInt32 = 0
        var g: UInt32 = 0
        var b: UInt32 = 0
        var a: UInt32 = 0
        let ok = stroke
            ? FPDFPageObj_GetStrokeColor(handle, &r, &g, &b, &a) != 0
            : FPDFPageObj_GetFillColor(handle, &r, &g, &b, &a) != 0
        return ok ? [r, g, b, a] : nil
    }

    private static func sameMarks(_ a: TextPiece, _ b: TextPiece) -> Bool {
        FPDFPageObj_CountMarks(a.handle) == FPDFPageObj_CountMarks(b.handle)
            && FPDFPageObj_GetMarkedContentID(a.handle) == FPDFPageObj_GetMarkedContentID(b.handle)
    }

    private static func sameClip(_ a: TextPiece, _ b: TextPiece) -> Bool {
        getClipSignature(a).dotNetSequenceEqual(getClipSignature(b))
    }

    private static func getClipSignature(_ piece: TextPiece) -> [Float] {
        if let cached = piece.clipSignature {
            return cached
        }

        var values: [Float] = []
        if let clip = FPDFPageObj_GetClipPath(piece.handle) {
            let paths = FPDFClipPath_CountPaths(clip)
            var p: Int32 = 0
            while p < paths {
                let segments = FPDFClipPath_CountPathSegments(clip, p)
                values.append(Float(segments))
                var s: Int32 = 0
                while s < segments {
                    let segment = FPDFClipPath_GetPathSegment(clip, p, s)
                    var x: Float = 0
                    var y: Float = 0
                    if let segment {
                        FPDFPathSegment_GetPoint(segment, &x, &y)
                    }

                    values.append(segment == nil ? -1 : Float(FPDFPathSegment_GetType(segment)))
                    values.append(x)
                    values.append(y)
                    values.append(segment != nil && FPDFPathSegment_GetClose(segment) != 0 ? 1 : 0)
                    s += 1
                }

                p += 1
            }
        }

        piece.clipSignature = values
        return values
    }

    private static func createRun(_ pageIndex: Int, _ pieces: [TextPiece], _ separators: [String]) -> TextRunLayout {
        var text: [UInt16] = []
        var bounds: PdfRect?
        for i in 0..<pieces.count {
            text.append(contentsOf: pieces[i].text.utf16)
            if i < separators.count {
                text.append(contentsOf: separators[i].utf16)
            }

            if let pieceBounds = pieces[i].bounds {
                bounds = bounds.map { $0.union(pieceBounds) } ?? pieceBounds
            }
        }

        let first = pieces[0]
        let (fontName, isSubset) = readFontName(first.font)
        let m = first.matrix
        let scale: Float = first.hasMatrix ? ((m.c * m.c) + (m.d * m.d)).squareRoot() : 1
        let fullText = String(units: text)
        let run = PdfTextRun(
            pageIndex,
            first.objectIndex,
            pieces.count,
            fullText.dotNetTrimEnd(),
            bounds ?? PdfRect(0, 0, 0, 0),
            fontName,
            first.font != nil && FPDFFont_GetIsEmbedded(first.font) == 1,
            isSubset,
            first.fontSize * scale,
            first.renderMode == Int(FPDF_TEXTRENDERMODE_INVISIBLE.rawValue))
        return TextRunLayout(run, pieces, separators, fullText)
    }

    private static func readFontName(_ font: FPDF_FONT?) -> (name: String, isSubset: Bool) {
        guard let font else {
            return ("(no font)", false)
        }

        let name = rawFontName(font)
        if name.length == 0 {
            return ("(unnamed font)", false)
        }

        // Subset fonts carry a six-uppercase-letter tag, e.g. "ABCDEF+Arial-BoldMT" (ISO 32000-1, 9.6.4).
        let units = name.units
        let isSubset = units.count > 7 && units[6] == 0x2B && units[0..<6].allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
        return (isSubset ? String(units: units[7...]) : name, isSubset)
    }

    /// The font's name as PDFium reports it, or empty.
    private static func rawFontName(_ font: FPDF_FONT) -> String {
        let length = FPDFFont_GetBaseFontName(font, nil, 0)
        if length <= 1 {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: length)
        FPDFFont_GetBaseFontName(font, &buffer, length)
        return Utf8.string(buffer[0..<(length - 1)].map { UInt8(bitPattern: $0) })
    }
}
