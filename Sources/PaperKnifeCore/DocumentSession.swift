import CPDFium
import Darwin
import Foundation

/// An open document and its edit history. Every change is a transaction: it is applied to a scratch
/// copy, serialized, reloaded and verified, and only then committed. A rejected change leaves the
/// document exactly as it was. Members are safe to call from any thread; calls are serialized.
public final class DocumentSession {
    private let password: String?

    // C#'s LinkedList of undo steps, oldest first, and Stack of redo steps, the next one last.
    private var undoHistory: [PdfSnapshot] = []
    private var redoHistory: [PdfSnapshot] = []
    private var contentPages: [Int: ContentPage?] = [:]
    private var document: PdfDocument
    private var current: PdfSnapshot
    private var saved: PdfSnapshot
    private var contentSnapshot: PdfSnapshot?
    private var contentFile: PdfFile?
    private var contentPageTree: [PdfPageNode]?
    private var disposed = false

    private init(_ snapshot: PdfSnapshot, _ password: String?, _ filePath: String?) throws {
        document = try PdfDocument.load(snapshot, password)
        current = snapshot
        saved = snapshot
        self.password = password
        self.filePath = filePath
    }

    /// C# disposes a session only when asked to; Swift has no `using`, so a session no longer
    /// referenced is disposed too, as `PdfDocument` is (its cached pages refer to it, so it isn't
    /// released on its own while the session holds it).
    deinit {
        dispose()
    }

    /// The file this session was opened from or last saved to, if any.
    public private(set) var filePath: String?

    /// Increments on every committed change, undo and redo.
    public private(set) var version = 0

    /// Approximate memory the undo history may use, in bytes. The newest undo step is always kept.
    public var historyLimitBytes = 512 * 1024 * 1024

    /// Whether text edits may be made in the content stream; tests turn it off to exercise PDFium's page rewrite.
    var useContentEditing = true

    public var isModified: Bool {
        PdfiumLibrary.withLock {
            current !== saved
        }
    }

    public var canUndo: Bool {
        PdfiumLibrary.withLock {
            !undoHistory.isEmpty
        }
    }

    public var canRedo: Bool {
        PdfiumLibrary.withLock {
            !redoHistory.isEmpty
        }
    }

    /// The verified, serialized state of the document. Saving writes exactly these bytes.
    public var currentSnapshot: PdfSnapshot {
        PdfiumLibrary.withLock {
            current
        }
    }

    public var pageCount: Int {
        get throws {
            try PdfiumLibrary.withLock {
                try throwIfDisposed()
                return try document.pageCount
            }
        }
    }

    public var signatureCount: Int {
        get throws {
            try PdfiumLibrary.withLock {
                try throwIfDisposed()
                return try document.signatureCount
            }
        }
    }

    /// Opens a file. A protected file without its password (or with a wrong one) throws a
    /// `PdfException` whose `errorCode` is `.passwordRequired`.
    public static func open(path: String, password: String? = nil) throws -> DocumentSession {
        let fullPath = try DotNetPath.getFullPath(path)
        return try DocumentSession(PdfSnapshot.fromFile(fullPath), password, fullPath)
    }

    public static func fromSnapshot(_ snapshot: PdfSnapshot, _ password: String? = nil) throws -> DocumentSession {
        try DocumentSession(snapshot, password, nil)
    }

    public func getPageSize(_ pageIndex: Int) throws -> PageSize {
        try PdfiumLibrary.withLock {
            let page = try getPage(pageIndex)
            return try PageSize(page.width, page.height)
        }
    }

    public func renderPage(_ pageIndex: Int, _ pixelWidth: Int, _ pixelHeight: Int) throws -> RenderedBitmap {
        try PdfiumLibrary.withLock {
            try getPage(pageIndex).render(pixelWidth, pixelHeight)
        }
    }

    public func getTextRuns(_ pageIndex: Int) throws -> [PdfTextRun] {
        try PdfiumLibrary.withLock {
            try getPage(pageIndex).getTextRuns()
        }
    }

    public func getTextRun(_ pageIndex: Int, _ objectIndex: Int) throws -> PdfTextRun? {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            return try isValidPage(pageIndex) ? document.getPage(pageIndex).tryGetTextRun(objectIndex) : nil
        }
    }

    public func hitTestText(_ pageIndex: Int, _ pixelWidth: Int, _ pixelHeight: Int, _ x: Int, _ y: Int) throws -> PdfTextRun? {
        try PdfiumLibrary.withLock {
            try getPage(pageIndex).hitTestText(pixelWidth, pixelHeight, x, y)
        }
    }

    public func mapToPixels(_ pageIndex: Int, _ rect: PdfRect, _ pixelWidth: Int, _ pixelHeight: Int) throws -> PixelRect {
        try PdfiumLibrary.withLock {
            try getPage(pageIndex).mapToPixels(rect, pixelWidth, pixelHeight)
        }
    }

    /// Reasons text on this page can't be edited yet; empty when editing is possible.
    public func getTextEditBlockers(_ pageIndex: Int) throws -> [String] {
        try PdfiumLibrary.withLock {
            let page = try getPage(pageIndex)
            var blockers: [String] = []
            if try !document.allowsContentChanges {
                blockers.append("The author of this PDF restricted editing.")
            }

            // Content PDFium can't rewrite only matters when PDFium has to rewrite the page.
            var rewritten = true
            if let content = try getContentPage(pageIndex) {
                let counts = try page.countObjects()
                rewritten = content.text.objectShows.count != counts.text
            }

            if rewritten {
                try blockers.append(contentsOf: Self.findContentBlockers(page))
            }

            return blockers
        }
    }

    /// Replaces the text of a run, keeping its font, size, position and color. Only the text
    /// objects whose characters change are rewritten; the rest of the run keeps its characters and
    /// moves along the baseline to make room. Trailing whitespace is dropped: it is invisible, and
    /// a character the font can't draw there would be impossible to detect. Empty text deletes the
    /// whole run.
    ///
    /// When PaperKnife can read the page's content with certainty, only the text-showing
    /// operations involved change, in the content stream itself (see `ContentTextEdit`); otherwise
    /// PDFium regenerates the page.
    /// - Parameter objectIndex: Any page object of the run, normally `PdfTextRun.objectIndex`.
    @discardableResult
    public func replaceText(_ pageIndex: Int, _ objectIndex: Int, _ newText: String) throws -> EditResult {
        let text = newText.dotNetTrimEnd()
        return try PdfiumLibrary.withLock {
            try replaceTextLocked(pageIndex, objectIndex, text)
        }
    }

    private func replaceTextLocked(_ pageIndex: Int, _ objectIndex: Int, _ text: String) throws -> EditResult {
        try throwIfDisposed()
        if try !isValidPage(pageIndex) {
            return EditResult.rejected(.invalidTarget, "That page no longer exists.")
        }

        let page = try document.getPage(pageIndex)
        let (pagePieces, runs) = try page.getTextLayout()
        guard let layout = runs.first(where: { $0.contains(objectIndex) }) else {
            return EditResult.rejected(.invalidTarget, "The selected text no longer exists. Select it again.")
        }

        let original = layout.run
        let deletes = text.length == 0
        if try !deletes && TextEquivalence.areEquivalent(text, original.text) {
            return EditResult.noChange("The text is unchanged.")
        }

        if try !document.allowsContentChanges {
            return EditResult.rejected(.editingRestricted, "The author of this PDF restricted editing.")
        }

        let edit = try deletes
            ? TextRunEdit.deleteAll(layout.pieces.count)
            : TextRunEdit.plan(layout.pieces.map { $0.text }, layout.separators, text)
        let pageCount = try document.pageCount
        let countsBefore = try page.countObjects()
        let (width, height) = try EditVerifier.checkSize(page.width, page.height)

        var candidate: PdfSnapshot?
        var change: RunChange?
        var addedFont: String?
        var glyphsToCheck: String?
        var copyFont: String?
        if let content = try getContentPage(pageIndex) {
            let prepared: ContentEditResult
            do {
                prepared = try ContentTextEdit.prepare(content, pagePieces, layout, edit)
            } catch let error where Self.isReadFailure(error) {
                prepared = ContentEditResult(.notApplicable, Self.message(of: error))
            }

            if prepared.outcome == .rejected {
                return prepared.rejection!
            }

            if prepared.outcome == .ready {
                candidate = try PdfSnapshot.fromBytes(prepared.candidate!)
                change = prepared.change!
                addedFont = prepared.addedFont
                glyphsToCheck = prepared.glyphsToCheck
                copyFont = prepared.copyFont
            }
        }

        if candidate == nil {
            if let failure = try rewriteWithPdfium(pageIndex, page, pagePieces, layout, edit, width, height, &candidate, &change) {
                return failure
            }
        }

        let before = try renderWithoutObjects(current, pageIndex, change!.hiddenBefore, width, height)
        var verified: PdfDocument? = try PdfDocument.load(candidate!, password)
        defer {
            verified?.dispose()
        }

        var edited: PdfTextRun?
        var warnings: [String] = []
        if let problem = try verifyTextEdit(
            verified!, candidate!, pageCount, change!, countsBefore, before, pagePieces, glyphsToCheck, copyFont, &edited, &warnings) {
            return EditResult.rejected(.collateralChange, problem)
        }

        commit(candidate!, verified!)
        verified = nil
        let message = deletes
            ? "Text deleted. Verified: nothing else on this page changed."
            : change!.movedRest
            ? "Text updated, and the rest of the line moved to fit. Verified: nothing else on this page changed."
            : "Text updated. Verified: nothing else on this page changed."
        var details: [String] = []
        if let addedFont {
            details.append(
                "This PDF contained only the letters it used from the font “\(addedFont)”, so PaperKnife added a complete copy of that font from its own fonts for the new text. The rest of the document still uses the PDF's own font.")
        }

        return EditResult.applied(message, warnings, edited, details)
    }

    /// Makes an edit by having PDFium regenerate the page's content, for pages PaperKnife can't
    /// edit in the content stream. Refuses pages whose content PDFium can't write back unchanged.
    /// - Parameter pagePieces: The page's text objects.
    private func rewriteWithPdfium(
        _ pageIndex: Int,
        _ page: PdfPage,
        _ pagePieces: [TextPiece],
        _ layout: TextRunLayout,
        _ edit: TextRunEdit,
        _ width: Int,
        _ height: Int,
        _ candidate: inout PdfSnapshot?,
        _ change: inout RunChange?
    ) throws -> EditResult? {
        candidate = nil
        change = nil
        let blockers = try Self.findContentBlockers(page)
        if blockers.count > 0 {
            return EditResult.rejected(.pageNotEditable, blockers[0])
        }

        if edit.last + 1 < layout.pieces.count && !layout.pieces[edit.last].isEndKnown {
            return EditResult.rejected(
                .pageNotEditable, "PaperKnife can't measure exactly where this part of the line ends, so it can't move the rest of the line to fit.")
        }

        if edit.newText.length > 0 {
            let support = TextSupport.check(layout.pieces[edit.first].font, layout.run.fontName, edit.newText)
            if !support.isSupported {
                return EditResult.rejected(.unsupportedCharacters, support.problem!, support.characters)
            }
        }

        // PDFium's page rewrite encodes the edited object's whole text again, by the character map
        // or else its own reverse lookup. In a symbolic Type 1 font, as pdfTeX's are, the code it
        // picks may draw another glyph than the character, or carry the width of another one (see
        // ContentTextEdit), and PaperKnife can't check that here. Removing objects is safe.
        let piece = layout.pieces[edit.first]
        if edit.newText.length > 0 && piece.isEmbedded {
            let flags = FPDFFont_GetFlags(piece.font)
            if flags >= 0 && (flags & 4) != 0 && Self.isType1Program(piece.font) {
                return EditResult.rejected(
                    .pageNotEditable,
                    "PaperKnife can change text in the font “\(layout.run.fontName)” only by editing the page's drawing instructions directly, which it can't do on this page (for example because the PDF is encrypted). It can still delete the whole line.")
            }
        }

        // Deleting needs no rewrite check: nothing of the deleted text remains, and the checks after
        // the change cover everything else on the page, invisible text included.
        if !edit.deletesAll(layout.pieces.count) {
            let runObjects = layout.pieces.map { $0.objectIndex }
            if let rewriteProblem = try checkRewriteKeepsAppearance(pageIndex, runObjects, page.render(width, height), pagePieces) {
                return EditResult.rejected(.pageNotEditable, rewriteProblem)
            }
        }

        let scratch = try PdfDocument.load(current, password)
        defer {
            scratch.dispose()
        }

        var applied: RunChange?
        if let failure = try Self.applyRunEdit(scratch.getPage(pageIndex), layout, edit, &applied) {
            return failure
        }

        candidate = try scratch.save()
        change = applied
        return nil
    }

    /// Whether a font is embedded as a Type 1 program, whose glyphs PDFium selects by name.
    private static func isType1Program(_ font: FPDF_FONT?) -> Bool {
        var length = 0
        guard let font, FPDFFont_GetFontData(font, nil, 0, &length) != 0, length >= 2, length <= Int(Int32.max) else {
            return false
        }

        var data = [UInt8](repeating: 0, count: length)
        let capacity = length
        let read = data.withUnsafeMutableBufferPointer { FPDFFont_GetFontData(font, $0.baseAddress, capacity, &length) }
        if read == 0 {
            return false
        }

        // A Type 1 program starts with its cleartext ("%!PS-AdobeFont" or "%!FontType1"), or a PFB segment header.
        return (data[0] == UInt8(ascii: "%") && data[1] == UInt8(ascii: "!")) || (data[0] == 0x80 && data[1] == 0x01)
    }

    /// Rotates a page clockwise by the given number of quarter turns.
    @discardableResult
    public func rotatePage(_ pageIndex: Int, _ quarterTurns: Int) throws -> EditResult {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            if try !isValidPage(pageIndex) {
                return EditResult.rejected(.invalidTarget, "That page no longer exists.")
            }

            let turns = ((quarterTurns % 4) + 4) % 4
            if turns == 0 {
                return EditResult.noChange("The page orientation is unchanged.")
            }

            let expected = try (document.getPage(pageIndex).rotation + turns) % 4
            let pageCount = try document.pageCount
            return try applyPageChange(
                { scratch in
                    try scratch.rotatePage(pageIndex, turns)
                    return true
                },
                { verified in try verified.pageCount == pageCount && verified.getPage(pageIndex).rotation == expected },
                "Page \(pageIndex + 1) rotated.")
        }
    }

    @discardableResult
    public func deletePage(_ pageIndex: Int) throws -> EditResult {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            if try !isValidPage(pageIndex) {
                return EditResult.rejected(.invalidTarget, "That page no longer exists.")
            }

            let pageCount = try document.pageCount
            if pageCount == 1 {
                return EditResult.rejected(.invalidTarget, "A PDF needs at least one page.")
            }

            return try applyPageChange(
                { scratch in
                    try scratch.deletePage(pageIndex)
                    return true
                },
                { verified in try verified.pageCount == pageCount - 1 },
                "Page \(pageIndex + 1) deleted.")
        }
    }

    /// Moves a page so that it ends up at `toIndex`.
    @discardableResult
    public func movePage(_ fromIndex: Int, _ toIndex: Int) throws -> EditResult {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            if try !isValidPage(fromIndex) || !isValidPage(toIndex) {
                return EditResult.rejected(.invalidTarget, "That page no longer exists.")
            }

            if fromIndex == toIndex {
                return EditResult.noChange("The page is already there.")
            }

            let pageCount = try document.pageCount
            return try applyPageChange(
                { scratch in try scratch.movePage(fromIndex, toIndex) },
                { verified in try verified.pageCount == pageCount },
                "Page \(fromIndex + 1) moved to position \(toIndex + 1).")
        }
    }

    /// Adds every page of another PDF to the end of this one.
    @discardableResult
    public func appendDocument(_ other: PdfSnapshot, _ password: String? = nil) throws -> EditResult {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            let source = try PdfDocument.load(other, password)
            defer {
                source.dispose()
            }

            if try !source.allowsCopyingPages {
                return EditResult.rejected(.editingRestricted, "The author of that PDF restricted copying its pages.")
            }

            let added = try source.pageCount
            let pageCount = try document.pageCount
            return try applyPageChange(
                { scratch in try scratch.importPages(source, pageCount) },
                { verified in try verified.pageCount == pageCount + added },
                added == 1 ? "1 page added." : "\(added) pages added.")
        }
    }

    @discardableResult
    public func undo() throws -> Bool {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            guard let last = undoHistory.last else {
                return false
            }

            let loaded = try PdfDocument.load(last, password)
            undoHistory.removeLast()
            redoHistory.append(current)
            replace(last, loaded)
            return true
        }
    }

    @discardableResult
    public func redo() throws -> Bool {
        try PdfiumLibrary.withLock {
            try throwIfDisposed()
            guard let next = redoHistory.last else {
                return false
            }

            let loaded = try PdfDocument.load(next, password)
            redoHistory.removeLast()
            undoHistory.append(current)
            replace(next, loaded)
            return true
        }
    }

    /// Writes the current snapshot to `path` through a temporary file in the same folder, so an
    /// existing file is replaced in one step and never left half-written.
    public func saveAs(path: String) throws {
        let fullPath = try DotNetPath.getFullPath(path)
        guard let directory = DotNetPath.getDirectoryName(fullPath) else {
            throw ArgumentException("Choose a file in a folder.", "path")
        }

        let snapshot = currentSnapshot
        let temporary = DotNetPath.combine(directory, "~\(DotNetPath.getFileName(fullPath)).\(Self.newGuid()).tmp")
        do {
            try Self.writeNewFile(temporary, snapshot)

            // File.Move(temporary, fullPath, overwrite: true), which renames on macOS.
            if Darwin.rename(temporary, fullPath) != 0 {
                throw Self.fileError(errno, fullPath)
            }
        } catch {
            Self.tryDelete(temporary)
            throw error
        }

        PdfiumLibrary.withLock {
            saved = snapshot
            filePath = fullPath
        }
    }

    public func dispose() {
        PdfiumLibrary.withLock {
            if disposed {
                return
            }

            document.dispose()
            undoHistory.removeAll()
            redoHistory.removeAll()
            disposed = true
        }
    }

    /// Applies a planned edit to the scratch copy of a page: the first changed object takes the new
    /// text, the other changed objects are removed, and the objects after them move along the
    /// baseline by however much longer or shorter the new text is, so the rest of the run keeps its
    /// spacing.
    private static func applyRunEdit(_ page: PdfPage, _ layout: TextRunLayout, _ edit: TextRunEdit, _ change: inout RunChange?) throws -> EditResult? {
        change = nil
        let pieces = layout.pieces
        let first = pieces[edit.first]
        let keepsFirst = edit.newText.length > 0
        let start = layout.distanceAlongBaseline(Double(first.matrix.e), Double(first.matrix.f))
        var end = start
        var trimmedEnd = start
        if keepsFirst {
            guard let textObject = try page.getTextObject(first.objectIndex), page.setText(textObject, edit.newText) else {
                return EditResult.rejected(.engineError, "PDFium couldn't change this text.")
            }

            // PDFium sets new text without kerning, one advance width after another.
            end = try start + page.measureText(first.objectIndex, edit.newText)
            trimmedEnd = try start + page.measureText(first.objectIndex, edit.newText.dotNetTrimEnd())
        }

        // Remove from the end, so the indexes of the objects still to remove stay valid.
        let firstRemoved = keepsFirst ? edit.first + 1 : edit.first
        var i = edit.last
        while i >= firstRemoved {
            if try !page.removeObject(pieces[i].objectIndex) {
                return EditResult.rejected(.engineError, "PDFium couldn't change this text.")
            }

            i -= 1
        }

        let removed = edit.last - firstRemoved + 1
        let rest = Array(pieces.dropFirst(edit.last + 1))
        let delta = end - layout.endAlongBaseline(pieces[edit.last])
        let moves = rest.count > 0 && abs(delta) > Double(first.fontSize) * 1e-3
        let (dx, dy) = moves ? (delta * Double(first.matrix.a), delta * Double(first.matrix.b)) : (0.0, 0.0)
        for piece in moves ? rest : [] {
            if try !page.translateObject(piece.objectIndex - removed, dx, dy) {
                return EditResult.rejected(.engineError, "PDFium couldn't move the rest of the line.")
            }
        }

        if edit.newText.dotNetTrim().length > 0 {
            // FPDFText_SetText silently turns characters it can't encode into character code 0.
            let stored = try page.getTextLayout().pieces.first { $0.objectIndex == first.objectIndex }
            if try stored == nil || !TextEquivalence.areEquivalentIgnoringSpacing(stored!.text, edit.newText) {
                return try EditResult.rejected(
                    .unsupportedCharacters,
                    "The font “\(layout.run.fontName)” in this PDF can't represent some of these characters.",
                    TextEquivalence.lost(edit.newText, stored?.text ?? ""))
            }
        }

        var hiddenBefore = pieces.dropFirst(edit.first).prefix(edit.last - edit.first + 1).map { $0.objectIndex }
        var hiddenAfter: [Int] = keepsFirst ? [first.objectIndex] : []
        if moves {
            hiddenBefore.append(contentsOf: rest.map { $0.objectIndex })
            hiddenAfter.append(contentsOf: rest.map { $0.objectIndex - removed })
        }

        change = RunChange(layout, edit, removed, dx, dy, end, trimmedEnd, hiddenBefore, hiddenAfter)
        return nil
    }

    /// - Parameters:
    ///   - piecesBefore: The page's text objects before the edit.
    ///   - glyphsToCheck: New characters that must have a glyph in the edited text's font in the
    ///     candidate (the font changed with the edit).
    ///   - copyFont: The name of the complete copy of a font the edited text is drawn with, if any
    ///     (see `FontCompletion`).
    private func verifyTextEdit(
        _ verified: PdfDocument,
        _ candidate: PdfSnapshot,
        _ pageCount: Int,
        _ change: RunChange,
        _ countsBefore: PageObjectCounts,
        _ before: RenderedBitmap,
        _ piecesBefore: [TextPiece],
        _ glyphsToCheck: String?,
        _ copyFont: String?,
        _ edited: inout PdfTextRun?,
        _ warnings: inout [String]
    ) throws -> String? {
        edited = nil
        warnings = []
        if try verified.pageCount != pageCount {
            return "Saving changed the number of pages, so the edit was cancelled."
        }

        let original = change.layout.run
        let page = try verified.getPage(original.pageIndex)
        var expected = countsBefore
        expected.text = countsBefore.text - change.removed
        let countsAfter = try page.countObjects()
        if countsAfter != expected {
            return "Rewriting this page would drop or alter other content (\(expected) expected; \(countsAfter) after), so the edit was cancelled."
        }

        let (pieces, runs) = try page.getTextLayout()
        var byIndex: [Int: TextPiece] = [:]
        for piece in pieces {
            byIndex[piece.objectIndex] = piece
        }

        let edit = change.edit
        let originalPieces = change.layout.pieces
        let deletes = edit.deletesAll(originalPieces.count)
        if try deletes && !Self.keepsOtherText(piecesBefore, change.hiddenBefore, byIndex) {
            return "Deleting this text would also change other text on the page, so it was cancelled."
        }

        let rest = Array(originalPieces.dropFirst(edit.last + 1))
        if edit.newText.dotNetTrim().length > 0 {
            guard let stored = byIndex[originalPieces[edit.first].objectIndex],
                try TextEquivalence.areEquivalentIgnoringSpacing(stored.text, edit.newText) else {
                return "The new text didn't survive saving, so the edit was cancelled."
            }

            // A font PDFium can't load is replaced by one of its own, which may draw every letter.
            if let copyFont, !stored.isEmbedded || !Type1Font.baseName(stored.fontName).ordinalEquals(copyFont) {
                return "PaperKnife couldn't confirm that the new text uses the font it added, so the edit was cancelled."
            }

            if let glyphsToCheck, glyphsToCheck.length > 0, !TextSupport.check(stored.font, original.fontName, glyphsToCheck).isSupported {
                return "PaperKnife couldn't confirm that the font draws the new letters, so the edit was cancelled."
            }

            // The rest of the run was placed after the advance widths of the new text, so PDFium
            // must lay it out that way. Checked here, not in memory: saving drops character and
            // word spacing. PDFium may or may not report the object's trailing spaces.
            let storedEnd = change.layout.endAlongBaseline(stored)
            let tolerance = Double(originalPieces[edit.first].fontSize) * 0.01
            if rest.count > 0 && abs(storedEnd - change.end) > tolerance && abs(storedEnd - change.trimmedEnd) > tolerance {
                return "PDFium laid out the new text differently than expected, so the edit was cancelled."
            }
        }

        let visible = try page.getVisibleBox()
        for piece in rest {
            // Spaces drawn on their own have no characters to compare; their position is checked.
            guard let moved = byIndex[piece.objectIndex - change.removed] else {
                return "The rest of the line didn't survive saving, so the edit was cancelled."
            }

            var lost = moved.hasCharacters != piece.hasCharacters
            if !lost && piece.hasCharacters {
                lost = try !TextEquivalence.areEquivalent(moved.text, piece.text)
            }

            if !lost {
                let shiftedX = abs(Double(moved.matrix.e) - (Double(piece.matrix.e) + change.shiftX))
                let shiftedY = abs(Double(moved.matrix.f) - (Double(piece.matrix.f) + change.shiftY))
                lost = shiftedX > 0.01 || shiftedY > 0.01
            }

            if lost {
                return "The rest of the line didn't survive saving, so the edit was cancelled."
            }

            if piece.hasCharacters, let from = piece.bounds, let to = moved.bounds, Self.sticksOutFurther(from, to, visible) {
                return "Moving the rest of the line would push part of it off the page, so the edit was cancelled."
            }
        }

        if try change.movedRest
            && !movedTextKeepsItsClipping(original.pageIndex, rest.map { $0.objectIndex }, change.shiftX, change.shiftY, before.width, before.height) {
            return "Moving the rest of the line would change how much of it shows, because the PDF clips it to an area, so the edit was cancelled."
        }

        // Hide the changed objects in both versions and compare the entire page, so content around,
        // under and over the edited text is checked too.
        let after = try renderWithoutObjects(candidate, original.pageIndex, change.hiddenAfter, before.width, before.height)
        let changed = EditVerifier.countChangedPixels(before, after)
        if changed > 0 {
            return "This edit would also change \(Self.formatN0(changed)) pixels elsewhere on the page (PDFium can't rewrite some spacing, shading or images exactly), so it was cancelled."
        }

        if !deletes {
            edited = runs.first(where: { $0.contains(original.objectIndex) })?.run
            guard let editedRun = edited else {
                return "The new text didn't survive saving, so the edit was cancelled."
            }

            for other in runs.map({ $0.run }) {
                if other.objectIndex != editedRun.objectIndex && !other.isInvisible
                    && other.bounds.intersects(editedRun.bounds) && !other.bounds.intersects(original.bounds) {
                    warnings.append("The new text now overlaps nearby text. Undo if that isn't what you want.")
                    break
                }
            }
        }

        if try verified.signatureCount > 0 {
            warnings.append("This PDF is digitally signed; editing it invalidates the signature.")
        }

        return nil
    }

    /// Whether every text object but the deleted ones is still there, in the same order, with the
    /// same text, geometry and rendering mode. Invisible text, which the page comparison can't
    /// see, is checked this way too.
    ///
    /// PDFium reads an object's text in the context of its neighbours: a hyphen or soft hyphen that
    /// ends a line reads as U+0002 only when more text follows on the next line, the spaces after
    /// it may be left out, and a copy drawn over other text (as for fake bold) reads as nothing. So
    /// text is compared as a reader sees it, and an object that read as nothing may now read as text.
    /// - Parameters:
    ///   - deleted: The page's indexes of the deleted objects before the edit.
    ///   - after: The page's text objects after the edit, by index.
    private static func keepsOtherText(_ before: [TextPiece], _ deleted: [Int], _ after: [Int: TextPiece]) throws -> Bool {
        // A hyphen or soft hyphen that ends a line reads as U+0002 while the next line follows it.
        func asWritten(_ text: String) -> String {
            String(units: text.utf16.map { $0 == 0x02 || $0 == 0xAD ? 0x2D : $0 })
        }

        let removed = deleted.sorted()
        for piece in before {
            let position = binarySearch(removed, piece.objectIndex)
            if position >= 0 {
                continue
            }

            // The objects after a deleted one move up by one index each.
            guard let kept = after[piece.objectIndex - ~position], kept.renderMode == piece.renderMode, sameGeometry(kept, piece) else {
                return false
            }

            if piece.hasCharacters {
                if !kept.hasCharacters {
                    return false
                }

                if try !TextEquivalence.areEquivalentIgnoringSpacing(asWritten(kept.text), asWritten(piece.text)) {
                    return false
                }
            }
        }

        return true
    }

    /// C#'s `List<int>.BinarySearch`: the index of `value`, or the bitwise complement of the index
    /// of the first element larger than it.
    private static func binarySearch(_ list: [Int], _ value: Int) -> Int {
        var low = 0
        var high = list.count - 1
        while low <= high {
            let i = low + ((high - low) >> 1)
            if list[i] == value {
                return i
            }

            if list[i] < value {
                low = i + 1
            } else {
                high = i - 1
            }
        }

        return ~low
    }

    /// Whether a text object is placed and spaced as it was: the same matrix, and the same bounds,
    /// which also change with letter and word spacing, as PDFium's page rewrite may drop them.
    private static func sameGeometry(_ kept: TextPiece, _ piece: TextPiece) -> Bool {
        let m = piece.matrix
        let k = kept.matrix
        let scale = DotNetMath.maximum(DotNetMath.maximum(abs(m.a), abs(m.b)), DotNetMath.maximum(abs(m.c), abs(m.d)))
        let tolerance = (Double(scale) * 1e-4) + 1e-6

        // The differences in single precision, as C# subtracts floats.
        let samePosition = Double(abs(k.e - m.e)) <= 0.01 && Double(abs(k.f - m.f)) <= 0.01
        let sameScale = Double(abs(k.a - m.a)) <= tolerance && Double(abs(k.b - m.b)) <= tolerance
        let sameSkew = Double(abs(k.c - m.c)) <= tolerance && Double(abs(k.d - m.d)) <= tolerance
        if kept.hasMatrix != piece.hasMatrix || !samePosition || !sameScale || !sameSkew {
            return false
        }

        switch (kept.bounds, piece.bounds) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return Double(abs(a.left - b.left)) <= 0.01 && Double(abs(a.bottom - b.bottom)) <= 0.01
                && Double(abs(a.right - b.right)) <= 0.01 && Double(abs(a.top - b.top)) <= 0.01
        default:
            return false
        }
    }

    /// Content that PDFium drops or can't reproduce when it rewrites a page's content stream
    /// (see docs/ARCHITECTURE.md). Pages containing it are refused up front.
    private static func findContentBlockers(_ page: PdfPage) throws -> [String] {
        var blockers: [String] = []
        let counts = try page.countObjects()
        if counts.shading > 0 {
            blockers.append("This page has gradient shading that PaperKnife can't rewrite safely yet.")
        }

        if counts.other > 0 {
            blockers.append("This page has content PaperKnife doesn't recognize.")
        }

        return blockers
    }

    private func applyPageChange(
        _ change: (PdfDocument) throws -> Bool, _ verify: (PdfDocument) throws -> Bool, _ successMessage: String
    ) throws -> EditResult {
        if try !document.allowsPageChanges {
            return EditResult.rejected(.editingRestricted, "The author of this PDF restricted changes to its pages.")
        }

        let candidate: PdfSnapshot
        do {
            let scratch = try PdfDocument.load(current, password)
            defer {
                scratch.dispose()
            }

            if try !change(scratch) {
                return EditResult.rejected(.engineError, "PDFium couldn't make this change.")
            }

            candidate = try scratch.save()
        }

        var verified: PdfDocument? = try PdfDocument.load(candidate, password)
        defer {
            verified?.dispose()
        }

        if try !verify(verified!) {
            return EditResult.rejected(.collateralChange, "The change didn't survive saving, so it was cancelled.")
        }

        commit(candidate, verified!)
        verified = nil
        return EditResult.applied(successMessage)
    }

    private func commit(_ snapshot: PdfSnapshot, _ loaded: PdfDocument) {
        undoHistory.append(current)
        redoHistory.removeAll()
        replace(snapshot, loaded)

        var total = undoHistory.reduce(0) { $0 + $1.length }
        while total > historyLimitBytes && undoHistory.count > 1 {
            total -= undoHistory[0].length
            undoHistory.removeFirst()
        }
    }

    private func replace(_ snapshot: PdfSnapshot, _ loaded: PdfDocument) {
        document.dispose()
        document = loaded
        current = snapshot
        contentSnapshot = nil
        contentFile = nil
        contentPageTree = nil
        contentPages.removeAll()
        version += 1
    }

    /// C#'s `File.Delete` where the error is ignored.
    private static func tryDelete(_ path: String) {
        _ = Darwin.unlink(path)
    }

    /// C#'s `Guid.NewGuid().ToString("N")`: 32 lowercase hexadecimal digits.
    private static func newGuid() -> String {
        UUID().uuidString.lowercased().ordinalReplacing("-", with: "")
    }

    /// C#'s `new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)`, the
    /// snapshot written to it, and `Flush(flushToDisk: true)`: a new file (it fails if the file
    /// exists), written through to the disk.
    private static func writeNewFile(_ path: String, _ snapshot: PdfSnapshot) throws {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        if descriptor < 0 {
            throw fileError(errno, path)
        }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try snapshot.writeTo(file)

        // .NET flushes to disk on macOS with F_FULLFSYNC; file systems without it take fsync.
        if fcntl(descriptor, F_FULLFSYNC) != 0 && fsync(descriptor) != 0 {
            throw fileError(errno, path)
        }

        try file.close()
    }

    /// The error for a failed file operation, as Foundation reports one, so the app can show its
    /// description (C# throws an IOException or UnauthorizedAccessException with the system's reason).
    private static func fileError(_ code: Int32, _ path: String) -> Error {
        let posix = POSIXErrorCode(rawValue: code) ?? .EIO
        let cocoa: CocoaError.Code
        switch posix {
        case .EACCES, .EPERM:
            cocoa = .fileWriteNoPermission
        case .ENOSPC, .EDQUOT:
            cocoa = .fileWriteOutOfSpace
        case .EROFS:
            cocoa = .fileWriteVolumeReadOnly
        case .EEXIST:
            cocoa = .fileWriteFileExists
        case .ENAMETOOLONG:
            cocoa = .fileWriteInvalidFileName
        case .ENOENT, .ENOTDIR:
            cocoa = .fileNoSuchFile
        default:
            cocoa = .fileWriteUnknown
        }

        return CocoaError(cocoa, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: POSIXError(posix)])
    }

    /// Renders a page of a snapshot with some objects hidden. The hidden state is never saved.
    private func renderWithoutObjects(_ snapshot: PdfSnapshot, _ pageIndex: Int, _ objectIndexes: [Int], _ width: Int, _ height: Int) throws -> RenderedBitmap {
        let loaded = try PdfDocument.load(snapshot, password)
        defer {
            loaded.dispose()
        }

        let page = try loaded.getPage(pageIndex)
        for objectIndex in objectIndexes {
            if try !page.setObjectActive(objectIndex, active: false) {
                throw PdfException(.operationFailed, "PDFium couldn't hide the edited text to verify the page.")
            }
        }

        return try page.render(width, height)
    }

    /// Has PDFium rewrite the page with nothing changed and checks it still looks the same. This
    /// covers the edited text's own styling (letter and word spacing, print colors), which the
    /// after-edit comparison can't see because it hides that text. Every text object must also keep
    /// its geometry, which covers text the rendering can't show, such as the invisible text of a
    /// scanned page: PDFium's rewrite drops letter and word spacing from all the text it rewrites.
    private func checkRewriteKeepsAppearance(_ pageIndex: Int, _ objectIndexes: [Int], _ original: RenderedBitmap, _ pagePieces: [TextPiece]) throws -> String? {
        let rewritten: PdfSnapshot
        do {
            let probe = try PdfDocument.load(current, password)
            defer {
                probe.dispose()
            }

            let page = try probe.getPage(pageIndex)
            for objectIndex in objectIndexes {
                if try !page.markObjectModified(objectIndex) {
                    return "PDFium couldn't prepare this text for editing."
                }
            }

            rewritten = try probe.save()
        }

        let reloaded = try PdfDocument.load(rewritten, password)
        defer {
            reloaded.dispose()
        }

        let rewrittenPage = try reloaded.getPage(pageIndex)
        let after = try rewrittenPage.render(original.width, original.height)
        if EditVerifier.countChangedPixels(original, after) != 0 {
            return "PaperKnife can't rewrite this page without changing how it looks (for example letter spacing, print colors or small embedded images), so its text can't be edited yet."
        }

        var rewrittenPieces: [Int: TextPiece] = [:]
        for piece in try rewrittenPage.getTextLayout().pieces {
            rewrittenPieces[piece.objectIndex] = piece
        }

        let keepsGeometry = pagePieces.allSatisfy { p in rewrittenPieces[p.objectIndex].map { Self.sameGeometry($0, p) } ?? false }
        return keepsGeometry
            ? nil
            : "PaperKnife can't rewrite this page without changing the spacing of some of its text (for example the invisible text of a scanned page), so its text can't be edited yet."
    }

    /// Whether moving the rest of a run leaves its clipping unchanged. Moving a text object doesn't
    /// move its clipping path, so moved text could be cut off at the edge of a clipped area, or text
    /// that was cut off could appear. On a copy of the original page, the objects are moved and
    /// rendered on their own, then rendered again with their clipping paths moved along with them;
    /// both must cover the same pixels. One copy keeps the glyph positions identical, and it keeps
    /// the clipping paths as saved: PDFium drops a rectangular clipping path when it loads a page
    /// in which the path contains its object. Comparing coverage rather than color catches white text.
    /// - Parameter moved: The moved objects' indexes in the original page.
    private func movedTextKeepsItsClipping(_ pageIndex: Int, _ moved: [Int], _ dx: Double, _ dy: Double, _ width: Int, _ height: Int) throws -> Bool {
        let loaded = try PdfDocument.load(current, password)
        defer {
            loaded.dispose()
        }

        let page = try loaded.getPage(pageIndex)
        if try !moved.contains(where: { try page.hasClipPath($0) }) {
            return true
        }

        try page.showOnly(moved)
        for i in moved {
            if try !page.translateObject(i, dx, dy) {
                return false
            }
        }

        let clipped = try page.renderOnTransparent(width, height)
        for i in moved {
            if try !page.translateClipPath(i, dx, dy) {
                return false
            }
        }

        return try EditVerifier.countChangedCoverage(clipped, page.renderOnTransparent(width, height)) == 0
    }

    /// Whether a moved object sticks out of the visible page further than before, on any side.
    private static func sticksOutFurther(_ before: PdfRect, _ after: PdfRect, _ page: PdfRect) -> Bool {
        let tolerance: Float = 0.01
        let zero: Float = 0
        let left = DotNetMath.maximum(zero, page.left - after.left) > DotNetMath.maximum(zero, page.left - before.left) + tolerance
        let right = DotNetMath.maximum(zero, after.right - page.right) > DotNetMath.maximum(zero, before.right - page.right) + tolerance
        let bottom = DotNetMath.maximum(zero, page.bottom - after.bottom) > DotNetMath.maximum(zero, page.bottom - before.bottom) + tolerance
        let top = DotNetMath.maximum(zero, after.top - page.top) > DotNetMath.maximum(zero, before.top - page.top) + tolerance
        return left || right || bottom || top
    }

    /// C#'s `{value:N0}`, which formats with the current culture: grouped digits, no decimals.
    private static func formatN0(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func getPage(_ pageIndex: Int) throws -> PdfPage {
        try throwIfDisposed()
        return try document.getPage(pageIndex)
    }

    private func isValidPage(_ pageIndex: Int) throws -> Bool { try pageIndex >= 0 && pageIndex < document.pageCount }

    private func throwIfDisposed() throws { try ObjectDisposedException.throwIf(disposed, self) }

    /// The page's content, read by PaperKnife's own parser, or nil when content editing is off or
    /// the file is encrypted or can't be read with certainty. Cached for the current snapshot.
    private func getContentPage(_ pageIndex: Int) throws -> ContentPage? {
        if !useContentEditing {
            return nil
        }

        if contentSnapshot !== current {
            contentSnapshot = current
            contentPages.removeAll()
            do {
                let opened = try PdfFile.tryOpen(current.memory)
                contentFile = opened?.isEncrypted == false ? opened : nil
                let pages = try contentFile?.getPages()
                if let pages, try pages.count == document.pageCount {
                    contentPageTree = pages
                } else {
                    contentPageTree = nil
                }
            } catch let error where Self.isReadFailure(error) {
                contentFile = nil
                contentPageTree = nil
            }
        }

        guard let file = contentFile, let tree = contentPageTree else {
            return nil
        }

        if let cached = contentPages[pageIndex] {
            return cached
        }

        if contentPages.count >= 16 {
            // The fonts and character maps read for those pages go with them.
            contentPages.removeAll()
            file.forgetDerived()
        }

        var page: ContentPage?
        do {
            page = try ContentPage.tryLoad(file, tree, pageIndex)
        } catch let error where Self.isReadFailure(error) {
            page = nil
        }

        contentPages.updateValue(page, forKey: pageIndex)
        return page
    }

    /// Exceptions from reading a damaged or unusual file with PaperKnife's own parser. Such files
    /// are left to PDFium rather than failing the operation. C# also lists KeyNotFoundException,
    /// FormatException, InvalidDataException and DivideByZeroException, which the Swift reader
    /// never throws (StreamFilters handles damaged Flate data itself).
    static func isReadFailure(_ error: Error) -> Bool {
        error is ArgumentException || error is IndexOutOfRangeException || error is InvalidCastException
            || error is InvalidOperationException || error is OverflowException || error is NullReferenceException
    }

    /// C#'s `ex.Message`.
    private static func message(of error: Error) -> String {
        (error as? DotNetException)?.message ?? "\(error)"
    }
}
