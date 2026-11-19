import CPDFium

/// A loaded page. Owned by its `PdfDocument` and invalid once the document is disposed.
public final class PdfPage {
    private static let maxRenderPixels = 120_000_000

    private let document: PdfDocument
    private var handleValue: FPDF_PAGE?
    private var contentDirty = false

    init(_ document: PdfDocument, _ handle: FPDF_PAGE, _ index: Int) {
        self.document = document
        handleValue = handle
        self.index = index
    }

    public let index: Int

    /// Displayed width in points (rotation applied).
    public var width: Float {
        get throws {
            try PdfiumLibrary.withLock {
                FPDF_GetPageWidthF(try handle)
            }
        }
    }

    /// Displayed height in points (rotation applied).
    public var height: Float {
        get throws {
            try PdfiumLibrary.withLock {
                FPDF_GetPageHeightF(try handle)
            }
        }
    }

    /// Clockwise rotation in quarter turns (0-3), from the page's /Rotate entry.
    public var rotation: Int {
        get throws {
            try PdfiumLibrary.withLock {
                max(0, Int(FPDFPage_GetRotation(try handle)))
            }
        }
    }

    var handle: FPDF_PAGE {
        get throws {
            guard let handleValue, !document.isDisposed else {
                throw ObjectDisposedException(objectName: "PdfPage")
            }

            return handleValue
        }
    }

    /// Renders the whole page, with annotations, onto a white background.
    public func render(_ pixelWidth: Int, _ pixelHeight: Int) throws -> RenderedBitmap { try render(pixelWidth, pixelHeight, 0xFFFF_FFFF) }

    /// Renders the page onto a transparent background, so the alpha channel shows what is drawn,
    /// in any color, white included.
    func renderOnTransparent(_ pixelWidth: Int, _ pixelHeight: Int) throws -> RenderedBitmap { try render(pixelWidth, pixelHeight, 0) }

    private func render(_ pixelWidth: Int, _ pixelHeight: Int, _ background: UInt32) throws -> RenderedBitmap {
        try ArgumentOutOfRangeException.throwIfLessThan(pixelWidth, 1, "pixelWidth")
        try ArgumentOutOfRangeException.throwIfLessThan(pixelHeight, 1, "pixelHeight")
        let (pixels64, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        try ArgumentOutOfRangeException.throwIfGreaterThan(overflow ? Int.max : pixels64, PdfPage.maxRenderPixels, "pixelWidth")

        let stride = pixelWidth * 4
        let count = stride * pixelHeight
        let pixels = try [UInt8](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            try PdfiumLibrary.withLock {
                let handle = try self.handle
                guard let bitmap = FPDFBitmap_CreateEx(Int32(pixelWidth), Int32(pixelHeight), FPDFBitmap_BGRA, buffer.baseAddress, Int32(stride)) else {
                    throw PdfException(.operationFailed, "There isn't enough memory to draw this page.")
                }

                defer { FPDFBitmap_Destroy(bitmap) }
                FPDFBitmap_FillRect(bitmap, 0, 0, Int32(pixelWidth), Int32(pixelHeight), FPDF_DWORD(background))
                FPDF_RenderPageBitmap(bitmap, handle, 0, 0, Int32(pixelWidth), Int32(pixelHeight), 0, FPDF_ANNOT)
            }

            initializedCount = count
        }

        return RenderedBitmap(pixelWidth, pixelHeight, stride, pixels)
    }

    public func countObjects() throws -> PageObjectCounts {
        try PdfiumLibrary.withLock {
            let handle = try self.handle
            var text = 0, path = 0, image = 0, shading = 0, form = 0, other = 0
            let count = FPDFPage_CountObjects(handle)
            var i: Int32 = 0
            while i < count {
                switch FPDFPageObj_GetType(FPDFPage_GetObject(handle, i)) {
                case FPDF_PAGEOBJ_TEXT: text += 1
                case FPDF_PAGEOBJ_PATH: path += 1
                case FPDF_PAGEOBJ_IMAGE: image += 1
                case FPDF_PAGEOBJ_SHADING: shading += 1
                case FPDF_PAGEOBJ_FORM: form += 1
                default: other += 1
                }

                i += 1
            }

            return PageObjectCounts(text, path, image, shading, form, other)
        }
    }

    /// All top-level text runs, in drawing order. Text nested in form XObjects is not included.
    public func getTextRuns() throws -> [PdfTextRun] {
        try PdfiumLibrary.withLock {
            TextLayout.build(try handle, index).runs.map { $0.run }
        }
    }

    /// The run that contains the page object at `objectIndex`, if it is text.
    public func tryGetTextRun(_ objectIndex: Int) throws -> PdfTextRun? {
        try PdfiumLibrary.withLock {
            try getRunLayout(objectIndex)?.run
        }
    }

    /// Finds the most specific visible text run under a pixel of a rendering of the given size.
    public func hitTestText(_ pixelWidth: Int, _ pixelHeight: Int, _ x: Int, _ y: Int) throws -> PdfTextRun? {
        try PdfiumLibrary.withLock {
            var pageX = 0.0
            var pageY = 0.0
            let handle = try self.handle
            if FPDF_DeviceToPage(
                handle, 0, 0, Int32(truncatingIfNeeded: pixelWidth), Int32(truncatingIfNeeded: pixelHeight), 0,
                Int32(truncatingIfNeeded: x), Int32(truncatingIfNeeded: y), &pageX, &pageY) == 0 {
                return nil
            }

            var best: PdfTextRun?
            for run in try getTextRuns() {
                if run.text.isDotNetWhiteSpace || !run.bounds.inflate(1).contains(pageX, pageY) {
                    continue
                }

                if best.map({ PdfPage.isBetterHit(run, $0) }) ?? true {
                    best = run
                }
            }

            return best
        }
    }

    private static func isBetterHit(_ candidate: PdfTextRun, _ current: PdfTextRun) -> Bool {
        // Visible text wins over invisible OCR layers, then the most specific run, then the topmost one.
        if candidate.isInvisible != current.isInvisible {
            return !candidate.isInvisible
        }

        if candidate.bounds.area != current.bounds.area {
            return candidate.bounds.area < current.bounds.area
        }

        return candidate.objectIndex > current.objectIndex
    }

    /// Maps a page-space rectangle to the pixels it covers in a rendering of the given size.
    public func mapToPixels(_ rect: PdfRect, _ pixelWidth: Int, _ pixelHeight: Int) throws -> PixelRect {
        try PdfiumLibrary.withLock {
            let handle = try self.handle
            let xs = [Double(rect.left), Double(rect.left), Double(rect.right), Double(rect.right)]
            let ys = [Double(rect.bottom), Double(rect.top), Double(rect.bottom), Double(rect.top)]
            var minX = Int32.max, minY = Int32.max, maxX = Int32.min, maxY = Int32.min

            // Declared once, as the C# locals are: a failed call would leave the previous values.
            var deviceX: Int32 = 0
            var deviceY: Int32 = 0
            for i in 0..<4 {
                FPDF_PageToDevice(
                    handle, 0, 0, Int32(truncatingIfNeeded: pixelWidth), Int32(truncatingIfNeeded: pixelHeight), 0, xs[i], ys[i],
                    &deviceX, &deviceY)
                minX = min(minX, deviceX)
                minY = min(minY, deviceY)
                maxX = max(maxX, deviceX)
                maxY = max(maxY, deviceY)
            }

            return PixelRect(Int(minX), Int(minY), Int(maxX &- minX), Int(maxY &- minY))
        }
    }

    func getTextObject(_ objectIndex: Int) throws -> FPDF_PAGEOBJECT? {
        let handle = try self.handle
        if objectIndex < 0 || objectIndex >= Int(FPDFPage_CountObjects(handle)) {
            return nil
        }

        guard let obj = FPDFPage_GetObject(handle, Int32(objectIndex)) else {
            return nil
        }

        return FPDFPageObj_GetType(obj) == FPDF_PAGEOBJ_TEXT ? obj : nil
    }

    /// The page's top-level text objects and the runs they form, valid until the page changes.
    func getTextLayout() throws -> (pieces: [TextPiece], runs: [TextRunLayout]) { TextLayout.build(try handle, index) }

    /// The run that contains the page object at `objectIndex`, with the objects it is made of.
    func getRunLayout(_ objectIndex: Int) throws -> TextRunLayout? {
        try getTextLayout().runs.first { $0.contains(objectIndex) }
    }

    /// Hides or shows one object in memory, for example to render a page without it.
    func setObjectActive(_ objectIndex: Int, active: Bool) throws -> Bool {
        let handle = try self.handle
        if objectIndex < 0 || objectIndex >= Int(FPDFPage_CountObjects(handle)) {
            return false
        }

        guard let obj = FPDFPage_GetObject(handle, Int32(objectIndex)) else {
            return false
        }

        return FPDFPageObj_SetIsActive(obj, active ? 1 : 0) != 0
    }

    /// Marks one object as modified without changing it (an identity transform), so the next save
    /// makes PDFium rewrite the content stream that contains it.
    func markObjectModified(_ objectIndex: Int) throws -> Bool {
        let handle = try self.handle
        if objectIndex < 0 || objectIndex >= Int(FPDFPage_CountObjects(handle)) {
            return false
        }

        guard let obj = FPDFPage_GetObject(handle, Int32(objectIndex)) else {
            return false
        }

        FPDFPageObj_Transform(obj, 1, 0, 0, 1, 0, 0)
        contentDirty = true
        return true
    }

    func setText(_ textObject: FPDF_PAGEOBJECT, _ text: String) -> Bool {
        // FPDF_WIDESTRING is NUL-terminated UTF-16, as .NET strings are in memory.
        let units = text.units + [0]
        let changed = units.withUnsafeBufferPointer { FPDFText_SetText(textObject, $0.baseAddress) }
        if changed == 0 {
            return false
        }

        contentDirty = true
        return true
    }

    /// Removes one object from the page and frees it.
    func removeObject(_ objectIndex: Int) throws -> Bool {
        let handle = try self.handle
        if objectIndex < 0 || objectIndex >= Int(FPDFPage_CountObjects(handle)) {
            return false
        }

        guard let obj = FPDFPage_GetObject(handle, Int32(objectIndex)), FPDFPage_RemoveObject(handle, obj) != 0 else {
            return false
        }

        FPDFPageObj_Destroy(obj)
        contentDirty = true
        return true
    }

    /// The advance width of `text` in a text object's font and size, in its text space units.
    func measureText(_ objectIndex: Int, _ text: String) throws -> Double {
        guard let obj = try getTextObject(objectIndex) else {
            return .nan
        }

        var size: Float = 0
        FPDFTextObj_GetFontSize(obj, &size)
        return TextLayout.measure(FPDFTextObj_GetFont(obj), size, text)
    }

    /// Moves one object by a page-space offset.
    func translateObject(_ objectIndex: Int, _ dx: Double, _ dy: Double) throws -> Bool {
        let handle = try self.handle
        if objectIndex < 0 || objectIndex >= Int(FPDFPage_CountObjects(handle)) {
            return false
        }

        guard let obj = FPDFPage_GetObject(handle, Int32(objectIndex)) else {
            return false
        }

        FPDFPageObj_Transform(obj, 1, 0, 0, 1, dx, dy)
        contentDirty = true
        return true
    }

    /// The part of the page that is shown: its media box cut to its crop box, in page space.
    func getVisibleBox() throws -> PdfRect {
        var box = FsRectF()
        return FPDF_GetPageBoundingBox(try handle, &box) != 0
            ? PdfRect(box.left, box.bottom, box.right, box.top)
            : PdfRect(-.infinity, -.infinity, .infinity, .infinity)
    }

    /// Whether a page object is clipped by at least one path.
    func hasClipPath(_ objectIndex: Int) throws -> Bool {
        guard let obj = try getObjectHandle(objectIndex), let clip = FPDFPageObj_GetClipPath(obj) else {
            return false
        }

        return FPDFClipPath_CountPaths(clip) > 0
    }

    /// Moves one object's clipping path by a page-space offset, in memory only, for example to render it.
    func translateClipPath(_ objectIndex: Int, _ dx: Double, _ dy: Double) throws -> Bool {
        guard let obj = try getObjectHandle(objectIndex) else {
            return false
        }

        FPDFPageObj_TransformClipPath(obj, 1, 0, 0, 1, dx, dy)
        return true
    }

    /// Hides every object except the given ones, in memory, to render them on their own.
    func showOnly(_ objectIndexes: [Int]) throws {
        let handle = try self.handle
        let shown = Set(objectIndexes)
        let count = FPDFPage_CountObjects(handle)
        var i: Int32 = 0
        while i < count {
            FPDFPageObj_SetIsActive(FPDFPage_GetObject(handle, i), shown.contains(Int(i)) ? 1 : 0)
            i += 1
        }
    }

    private func getObjectHandle(_ objectIndex: Int) throws -> FPDF_PAGEOBJECT? {
        let handle = try self.handle
        return objectIndex >= 0 && objectIndex < Int(FPDFPage_CountObjects(handle)) ? FPDFPage_GetObject(handle, Int32(objectIndex)) : nil
    }

    func setRotation(_ quarterTurns: Int) throws { FPDFPage_SetRotation(try handle, Int32(truncatingIfNeeded: quarterTurns)) }

    func markContentDirty() { contentDirty = true }

    func commitContent() throws {
        guard contentDirty, let handleValue else {
            return
        }

        if FPDFPage_GenerateContent(handleValue) == 0 {
            throw PdfException(.operationFailed, "PDFium couldn't rewrite the page content.")
        }

        contentDirty = false
    }

    func close() {
        if let handleValue {
            FPDF_ClosePage(handleValue)
            self.handleValue = nil
        }
    }
}
