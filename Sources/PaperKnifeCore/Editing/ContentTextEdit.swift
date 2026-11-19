import CPDFium

enum ContentEditOutcome {
    /// This edit can't be made in the content stream; PDFium's page rewrite may still do it.
    case notApplicable

    case rejected

    case ready
}

final class ContentEditResult {
    init(
        _ outcome: ContentEditOutcome,
        _ reason: String? = nil,
        rejection: EditResult? = nil,
        candidate: [UInt8]? = nil,
        change: RunChange? = nil,
        addedFont: String? = nil,
        glyphsToCheck: String? = nil,
        copyFont: String? = nil
    ) {
        self.outcome = outcome
        self.reason = reason
        self.rejection = rejection
        self.candidate = candidate
        self.change = change
        self.addedFont = addedFont
        self.glyphsToCheck = glyphsToCheck
        self.copyFont = copyFont
    }

    let outcome: ContentEditOutcome

    let reason: String?

    let rejection: EditResult?

    let candidate: [UInt8]?

    let change: RunChange?

    let addedFont: String?

    let glyphsToCheck: String?

    let copyFont: String?
}

/// Edits a run in the page's content stream itself instead of having PDFium regenerate the page:
/// only the text-showing operations of the run change, and the result is appended to the file as
/// an incremental update, so every other byte stays as it was. Content PDFium can't write back
/// (Type 3 fonts, letter and word spacing, print colors, inline images, shadings) is kept as is.
/// The candidate is verified like any other edit. Use only while holding `PdfiumLibrary`'s lock.
enum ContentTextEdit {
    private static let positionTolerance = 0.01

    static func prepare(_ page: ContentPage, _ pagePieces: [TextPiece], _ layout: TextRunLayout, _ edit: TextRunEdit) throws -> ContentEditResult {
        if page.text.objectShows.count != pagePieces.count {
            return notApplicable("The page's text objects don't match its content.")
        }

        // Fonts without a /Widths array (the standard 14) take their widths from PDFium. The
        // ordinals of the simulation below are those of `page.text`, whose count was just checked.
        func width(_ show: ShowOp, _ code: UInt32) -> Double? {
            show.font?.width(code) ?? (show.ordinal >= 0 ? pdfiumWidth(pagePieces[show.ordinal].font, show.font?.unicode(code)) : nil)
        }

        let text = try TextShowSimulator.run(page.ops, page.file, page.page.resources, width)
        var ordinals: [Int: Int] = [:]
        for i in 0..<pagePieces.count {
            ordinals[pagePieces[i].objectIndex] = i
        }

        // Every piece of the run is one of the page's pieces.
        let runShows = layout.pieces.map { text.objectShows[ordinals[$0.objectIndex]!] }
        if edit.deletesAll(layout.pieces.count) {
            return try delete(page, text, runShows, layout, edit, pagePieces)
        }

        let first = runShows[edit.first]
        let firstPiece = layout.pieces[edit.first]

        // A show with a font has a font name: the font was found by it.
        guard let font = first.font, font.codeLength == 1 || font.codeLength == 2, !first.inReplacedText, let firstFontName = first.fontName else {
            return notApplicable("PaperKnife can't encode text for this font.")
        }

        let layoutProblem = TextSupport.check(firstPiece.font, layout.run.fontName, edit.newText, checkGlyphs: false)
        if !layoutProblem.isSupported {
            return rejected(layoutProblem.problem!, layoutProblem.characters)
        }

        let count = edit.last - edit.first + 1
        let oldShows = Array(runShows[edit.first..<(edit.first + count)])
        let preferred = Set(oldShows.flatMap { $0.codes() }.map { $0.code })
        var knownWordGap: Double?
        let spaceCode = Self.spaceCode(font, firstPiece.font, layout.run.fontName, preferred)
        let old = try GlyphPlanner.readOldGlyphs(
            oldShows, Array(layout.pieces.dropFirst(edit.first).prefix(count)), Array(layout.separators.dropFirst(edit.first).prefix(count - 1)),
            width, first)
        let planner = GlyphPlanner(
            font: font,
            width: { width(first, $0) },
            preferred: preferred,
            spaceCode: spaceCode,
            wordGap: {
                if let known = knownWordGap {
                    return known
                }

                let gap = try Self.wordGap(text, pagePieces, font, width)
                knownWordGap = gap
                return gap
            },
            old: old)
        var plan = try planner.plan(edit.newText)
        if plan.missing.count > 0 && font.isType3 {
            return rejected(TextSupport.missingMessage(layout.run.fontName, plan.missing), plan.missing)
        }

        // Letters the font lacks: TeX embeds only those a document uses, and PaperKnife may have
        // the whole font. The new text then uses a complete copy of the font; nothing else does.
        var completion: FontCompletion?
        var support = plan.missing.isEmpty && plan.newCharacters.length > 0 && !font.isType3
            ? TextSupport.check(firstPiece.font, layout.run.fontName, plan.newCharacters)
            : TextSupportResult.supported
        if try support.isSupported && plan.newGlyphs.count > 0 && FontCompletion.selectsGlyphsByName(page, firstFontName) {
            let other = try plan.newGlyphs.filter { try !font.vouches($0.code, $0.text) }.map { $0.text }.distinctInOrder { OrdinalString($0) }
            if other.count > 0 {
                // pdfTeX's fonts name only the codes a document uses. At the others PDFium draws the
                // glyph the subset's own encoding gives them, if the subset has it for another code or
                // font, while the character map and the widths follow TeX's encoding. A copy of the font
                // can draw and space such letters right; without one they are refused.
                support = TextSupportResult(TextSupport.missingMessage(layout.run.fontName, other), other)
            }
        }

        if plan.missing.count > 0 || !support.isSupported {
            var difference: String?
            completion = try FontCompletion.tryCreate(page, firstFontName, &difference)
            guard let created = completion else {
                if plan.missing.count > 0 {
                    // PDFium may still encode them on its own; if it can't draw them either, say so.
                    support = TextSupport.check(firstPiece.font, layout.run.fontName, String(units: plan.missing.flatMap { Array($0.utf16) }))
                    if support.isSupported {
                        return notApplicable("The font's character map doesn't cover the new text.")
                    }
                }

                let problem = support.problem ?? ""
                return rejected(
                    difference.map { "\(problem). PaperKnife has its own copy of this font but can't use it here: \($0)." } ?? problem,
                    support.characters)
            }

            // Kept letters keep their codes, which select the same glyphs with the same widths in the copy.
            let copy = created.info
            plan = try GlyphPlanner(
                font: copy,
                width: { copy.width($0) },
                preferred: preferred,
                spaceCode: planner.spaceCode,
                wordGap: planner.wordGap,
                old: planner.old
            ).plan(edit.newText)
            let notDrawn = try (plan.missing + plan.newGlyphs.filter { try !created.draws($0.code, $0.text) }.map { $0.text })
                .distinctInOrder { OrdinalString($0) }
            if notDrawn.count > 0 {
                return rejected(TextSupport.missingMessage(layout.run.fontName, notDrawn), notDrawn)
            }
        }

        let glyphs = plan.glyphs
        if glyphs.contains(where: { $0.width.isNaN }) {
            return notApplicable("A character's width isn't known.")
        }

        // Ends along the baseline, in the units of TextRunLayout: the end of the last glyph,
        // leaving out the spacing after it, so the gap to the rest of the run stays the same.
        // Spaces drawn as gaps count, at either end.
        func start(_ show: ShowOp) -> Double { layout.distanceAlongBaseline(show.pageStart.x, show.pageStart.y) }
        let lead = glyphs.count > 0 ? -plan.initialKerning / 1000 * first.fontSize : 0
        let trail = plan.trailingKerning == 0 ? 0 : (-plan.trailingKerning / 1000 * first.fontSize) + (glyphs.count > 0 ? first.charSpace : 0)
        let end = try start(first) + lead + span(first, glyphs) + trail
        let trimmedEnd = try start(first) + lead + span(first, Array(glyphs.prefix(plan.visibleGlyphs)))
        let oldEnd: Double
        let lastPiece = layout.pieces[edit.last]
        if !lastPiece.hasCharacters {
            oldEnd = layout.endAlongBaseline(lastPiece)
        } else {
            let lastShow = runShows[edit.last]
            var oldGlyphs: [PlannedGlyph] = []
            for (code, kerning) in lastShow.codes() {
                guard let w = width(lastShow, code) else {
                    return notApplicable("A character's width isn't known.")
                }

                oldGlyphs.append(PlannedGlyph(code, w, kerning))
            }

            oldEnd = try start(lastShow) + span(lastShow, oldGlyphs)
        }

        let rest = Array(runShows.dropFirst(edit.last + 1))
        let shift = end - oldEnd
        let moves = rest.count > 0 && abs(shift) > Double(firstPiece.fontSize) * 1e-3
        let (dx, dy) = moves ? (shift * Double(firstPiece.matrix.a), shift * Double(firstPiece.matrix.b)) : (0.0, 0.0)

        let keepsFirst = glyphs.count > 0
        let removed = Array(runShows.dropFirst(keepsFirst ? edit.first + 1 : edit.first).prefix(edit.last - edit.first + (keepsFirst ? 0 : 1)))
        var roles: [Int: Role] = [:]
        if keepsFirst {
            roles[first.opIndex] = .edited
        }

        for show in removed {
            roles[show.opIndex] = .removed
        }

        for show in moves ? rest : [] {
            roles[show.opIndex] = .moved
        }

        let changedShows = Array(runShows.dropFirst(edit.first).prefix(edit.last - edit.first + 1)) + (moves ? rest : [])
        let blocks = changedShows.map { $0.block }.distinctInOrder().sorted()
        if let problem = checkBlocks(text, blocks, pagePieces) {
            return notApplicable(problem)
        }

        let switchFont: (copy: String, original: String, size: Double)? = completion.map {
            (copy: $0.resourceName, original: firstFontName, size: first.fontSize)
        }
        let operation = try editedOperation(completion?.info ?? font, plan)
        guard let content = try rewrite(page, text, blocks, roles, first, operation, (dx, dy), switchFont) else {
            return notApplicable("A moved text object's transformation can't be inverted.")
        }

        var updates: [ObjectUpdate] = page.streams.enumerated().map { (i, s) -> ObjectUpdate in
            StreamUpdate(s.number, s.generation, i == 0 ? content : [])
        }
        if let completion {
            try updates.append(contentsOf: completion.updates())
        }

        let candidate = try IncrementalUpdate.append(page.file, updates)

        let pieces = layout.pieces
        var hiddenBefore = pieces.dropFirst(edit.first).prefix(edit.last - edit.first + 1).map { $0.objectIndex }
        var hiddenAfter: [Int] = keepsFirst ? [firstPiece.objectIndex] : []
        if moves {
            hiddenBefore.append(contentsOf: pieces.dropFirst(edit.last + 1).map { $0.objectIndex })
            hiddenAfter.append(contentsOf: pieces.dropFirst(edit.last + 1).map { $0.objectIndex - removed.count })
        }

        let change = RunChange(layout, edit, removed.count, dx, dy, end, trimmedEnd, hiddenBefore, hiddenAfter)
        return ContentEditResult(
            .ready,
            candidate: candidate,
            change: change,
            addedFont: completion.flatMap { $0.reused ? nil : $0.fontName },
            glyphsToCheck: completion == nil ? nil : plan.newCharacters,
            copyFont: completion?.fontName)
    }

    /// Deletes a whole run: its text-showing operations are left out of their blocks, which are
    /// rewritten as for an edit, so the rest of each block keeps its place. Nothing is encoded, so
    /// any font will do.
    private static func delete(
        _ page: ContentPage, _ text: ContentTextLayout, _ runShows: [ShowOp], _ layout: TextRunLayout, _ edit: TextRunEdit, _ pagePieces: [TextPiece]
    ) throws -> ContentEditResult {
        if runShows.contains(where: { $0.inReplacedText }) {
            return notApplicable("The text has replacement text (/ActualText).")
        }

        var roles: [Int: Role] = [:]
        for show in runShows {
            roles[show.opIndex] = .removed
        }

        let blocks = runShows.map { $0.block }.distinctInOrder().sorted()
        if let problem = checkBlocks(text, blocks, pagePieces) {
            return notApplicable(problem)
        }

        guard let content = try rewrite(page, text, blocks, roles, runShows[0], "", (0, 0), nil) else {
            return notApplicable("The text blocks can't be rewritten.")
        }

        let updates = page.streams.enumerated().map { (i, s) -> ObjectUpdate in StreamUpdate(s.number, s.generation, i == 0 ? content : []) }
        let deleted = layout.pieces.map { $0.objectIndex }
        let change = RunChange(layout, edit, deleted.count, 0, 0, 0, 0, deleted, [])
        let candidate = try IncrementalUpdate.append(page.file, updates)
        return ContentEditResult(.ready, candidate: candidate, change: change)
    }

    /// The advance from a glyph sequence's origin to the end of its last glyph, along the baseline in
    /// TextRunLayout units (where horizontal scaling cancels out): widths, character and word
    /// spacing and TJ adjustments, but not the spacing after the last glyph.
    private static func span(_ show: ShowOp, _ glyphs: [PlannedGlyph]) throws -> Double {
        var total: Double = 0
        for i in 0..<glyphs.count {
            total += glyphs[i].width * show.fontSize
            if i < glyphs.count - 1 {
                var wordSpace: Double = 0
                if glyphs[i].code == 32 {
                    // C#'s show.Font!.CodeLength.
                    guard let font = show.font else {
                        throw DotNetThrows.nullReference()
                    }

                    if font.codeLength == 1 {
                        wordSpace = show.wordSpace
                    }
                }

                total += show.charSpace + wordSpace - (glyphs[i].kerningAfter / 1000 * show.fontSize)
            }
        }

        return total
    }

    /// A code that draws a space in this font, or nil when spaces have to be drawn as gaps.
    private static func spaceCode(_ font: PdfFontInfo, _ pdfiumFont: FPDF_FONT?, _ fontName: String, _ preferred: Set<UInt32>) -> UInt32? {
        var missing: [String] = []
        let codes = font.encode(" ", preferred, &missing)
        if missing.count > 0 || codes.count != 1 {
            return nil
        }

        return font.isType3 || TextSupport.check(pdfiumFont, fontName, " ").isSupported ? codes[0] : nil
    }

    /// The median gap between words, in thousandths of an em, among this font's text on the page:
    /// the TJ adjustments PDFium reads as spaces. A third of an em, TeX's usual word space, when
    /// there are none.
    private static func wordGap(
        _ text: ContentTextLayout, _ pagePieces: [TextPiece], _ font: PdfFontInfo, _ width: (ShowOp, UInt32) -> Double?
    ) throws -> Double {
        var gaps: [Double] = []
        for show in text.objectShows {
            if show.font === font, let glyphs = try GlyphPlanner.readOldGlyphs([show], [pagePieces[show.ordinal]], [], width, show) {
                gaps.append(contentsOf: glyphs.filter { $0.spaceAfter }.map { -$0.kerningAfter })
            }
        }

        if gaps.isEmpty {
            return 1000.0 / 3
        }

        // List<double>.Sort orders NaN first, as double.CompareTo does.
        gaps.sort { ($0.isNaN && !$1.isNaN) || $0 < $1 }
        return gaps[gaps.count / 2]
    }

    /// The text-showing operation for the new text: Tj, or TJ when it needs adjustments.
    private static func editedOperation(_ font: PdfFontInfo, _ plan: GlyphPlan) throws -> String {
        if !plan.hasAdjustments {
            return try CosWriter.toText(CosString(font.joinCodes(plan.glyphs.map { $0.code }))) + " Tj"
        }

        var operation = "["
        if plan.initialKerning != 0 {
            operation += CosWriter.number(plan.initialKerning) + " "
        }

        var codes: [UInt32] = []
        for i in 0..<plan.glyphs.count {
            codes.append(plan.glyphs[i].code)
            if i == plan.glyphs.count - 1 || plan.glyphs[i].kerningAfter != 0 {
                operation += try CosWriter.toText(CosString(font.joinCodes(codes)))
                if i < plan.glyphs.count - 1 {
                    operation += " " + CosWriter.number(plan.glyphs[i].kerningAfter) + " "
                }

                codes.removeAll()
            }
        }

        return operation + "] TJ"
    }

    /// The blocks are rewritten with an explicit position for every text-showing operation, so each
    /// one's position must be known and match where PDFium draws it.
    private static func checkBlocks(_ text: ContentTextLayout, _ blocks: [Int], _ pagePieces: [TextPiece]) -> String? {
        for index in blocks {
            if index < 0 || text.blocks[index].end < 0 || text.blocks[index].irregular {
                return "The text isn't in a simple text block."
            }

            for show in text.shows where show.block == index && show.producesObject {
                let piece = pagePieces[show.ordinal]
                let (x, y) = show.pageStart
                let m = show.objectMatrix
                let scale = DotNetMath.maximum(DotNetMath.maximum(abs(m.a), abs(m.b)), DotNetMath.maximum(abs(m.c), abs(m.d)))
                let tolerance = (scale * 1e-4) + 1e-6
                let positionDiffers = abs(x - Double(piece.matrix.e)) > positionTolerance || abs(y - Double(piece.matrix.f)) > positionTolerance
                let matrixDiffers = abs(m.a - Double(piece.matrix.a)) > tolerance || abs(m.b - Double(piece.matrix.b)) > tolerance
                    || abs(m.c - Double(piece.matrix.c)) > tolerance || abs(m.d - Double(piece.matrix.d)) > tolerance
                if !show.positionKnown || !piece.hasMatrix || positionDiffers || matrixDiffers {
                    return "PaperKnife couldn't confirm where the text is drawn."
                }
            }
        }

        return nil
    }

    /// The page content with each affected text block rewritten: positioning operators are replaced
    /// by an explicit Tm before every text-showing operation, the edited operation shows the new
    /// codes, removed ones are left out, and moved ones are shifted. Everything else is copied
    /// byte for byte.
    private static func rewrite(
        _ page: ContentPage,
        _ text: ContentTextLayout,
        _ blocks: [Int],
        _ roles: [Int: Role],
        _ edited: ShowOp,
        _ editedOperation: String,
        _ shift: (x: Double, y: Double),
        _ switchFont: (copy: String, original: String, size: Double)?
    ) throws -> [UInt8]? {
        let content = page.content
        var shows: [Int: ShowOp] = [:]
        for show in text.shows {
            shows[show.opIndex] = show
        }

        var output: [UInt8] = []
        output.reserveCapacity(content.count + 256)
        var copied = 0
        for index in blocks {
            let block = text.blocks[index]
            let start = page.ops[block.begin].start

            // MemoryStream.Write refuses a negative count.
            guard start >= copied else {
                throw DotNetThrows.spanOutOfRange()
            }

            output.append(contentsOf: content[copied..<start])
            for i in stride(from: block.begin, through: block.end, by: 1) {
                let op = page.ops[i]
                let raw = content[op.start..<op.end]
                let isShow = op.operator == "Tj" || op.operator == "TJ" || op.operator == "'" || op.operator == "\""
                if op.operator == "Td" || op.operator == "Tm" || op.operator == "T*" {
                    continue
                }

                if op.operator == "TD" {
                    // TD also sets the leading, which later text may use.
                    if op.operands.count == 2, op.operands[0] is CosNumber, let ty = op.operands[1] as? CosNumber {
                        write(&output, "\(CosWriter.number(-ty.value)) TL\n")
                    }

                    continue
                }

                guard isShow, let show = shows[i] else {
                    output.append(contentsOf: raw)
                    output.append(UInt8(ascii: "\n"))
                    continue
                }

                if op.operator == "\"" {
                    guard let wordSpace = op.operands[0] as? CosNumber, let charSpace = op.operands[1] as? CosNumber else {
                        throw DotNetThrows.invalidCast()
                    }

                    write(&output, "\(wordSpace.raw) Tw \(charSpace.raw) Tc\n")
                }

                let role = roles[i] ?? .unchanged
                if role == .removed {
                    continue
                }

                if role == .edited {
                    // Text drawn with a completed copy of the font selects the copy for itself only.
                    if let fonts = switchFont {
                        write(&output, "\(name(fonts.copy)) \(CosWriter.number(fonts.size)) Tf\n")
                    }

                    write(&output, "\(edited.glyphMatrix.toOperands()) Tm \(editedOperation)\n")
                    if let restore = switchFont {
                        write(&output, "\(name(restore.original)) \(CosWriter.number(restore.size)) Tf\n")
                    }

                    continue
                }

                var matrix = show.opMatrix
                if role == .moved {
                    guard let inverse = show.ctm.invert() else {
                        return nil
                    }

                    let (ux, uy) = inverse.transformVector(shift.x, shift.y)
                    matrix = PdfMatrix(matrix.a, matrix.b, matrix.c, matrix.d, matrix.e + ux, matrix.f + uy)
                }

                if show.producesObject {
                    write(&output, "\(matrix.toOperands()) Tm ")
                }

                if op.operator == "Tj" || op.operator == "TJ" {
                    output.append(contentsOf: raw)
                } else {
                    try write(&output, CosWriter.toText(op.operands[op.operands.count - 1]))
                    write(&output, " Tj")
                }

                output.append(UInt8(ascii: "\n"))
            }

            copied = page.ops[block.end].end
        }

        output.append(contentsOf: content[copied..<content.count])
        return output
    }

    private static func pdfiumWidth(_ font: FPDF_FONT?, _ text: String?) -> Double? {
        guard let font, let text, text.length == 1 else {
            return nil
        }

        var width: Float = 0
        return FPDFFont_GetGlyphWidth(font, UInt32(text.units[0]), 1, &width) != 0 && width > 0 ? Double(width) : nil
    }

    private static func write(_ output: inout [UInt8], _ text: String) { output.append(contentsOf: Latin1.bytes(text)) }

    private static func name(_ name: String) -> String {
        var text = ""
        CosWriter.writeName(&text, name)
        return text
    }

    private static func notApplicable(_ reason: String) -> ContentEditResult { ContentEditResult(.notApplicable, reason) }

    private static func rejected(_ message: String, _ characters: [String]) -> ContentEditResult {
        ContentEditResult(.rejected, rejection: EditResult.rejected(.unsupportedCharacters, message, characters))
    }

    private enum Role {
        case unchanged
        case edited
        case removed
        case moved
    }
}
