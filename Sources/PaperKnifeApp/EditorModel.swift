import AppKit
import Foundation

enum Severity {
    case informational
    case success
    case warning
    case error
}

/// The message bar at the top of the window.
struct Banner: Equatable {
    var severity: Severity
    var title: String
    var message: String
}

enum DialogChoice {
    case primary
    case secondary
    case cancel
}

/// What the editor asks of its window: questions and file choices.
@MainActor
protocol EditorPresenter: AnyObject {
    func ask(title: String, message: String, primary: String, secondary: String?, destructive: Bool) async -> DialogChoice
    func askPassword(fileName: String, retry: Bool) async -> String?
    func chooseFileToOpen() async -> URL?
    func chooseSaveLocation(suggestedName: String, directory: URL?) async -> URL?
}

/// A page as the window shows it.
struct DisplayedPage {
    var image: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
    /// The pixels per point of the screen the page was drawn for.
    var scale: CGFloat

    var size: CGSize { CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale) }
}

/// The most pixels a page is drawn with, however far it is zoomed in.
private let maxDisplayPixels = 40_000_000.0

/// What drawing a page gives, read together on the engine queue.
private struct Rendering {
    var bitmap: PageBitmap
    var blockers: [String]
    var runs: [TextRun]
    var selection: CGRect?
}

/// C#'s string.IsNullOrWhiteSpace: Unicode's White_Space property is the set char.IsWhiteSpace tests.
private func isBlank(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
}

/// The editor behind PaperKnife's window, with the commands, rules and messages of PaperKnife for
/// Windows' window. Engine calls run on one background queue. While a command runs, every control
/// that could start another engine call is disabled, and the views only read this model's copy of
/// the session's state, taken when the last command finished.
@MainActor
final class EditorModel: ObservableObject {
    static let zoomLevels: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    private static let queue = DispatchQueue(label: "io.github.shivam098.paperknife.engine", qos: .userInitiated)

    weak var presenter: EditorPresenter?

    @Published private(set) var editor: Editor?
    @Published private(set) var state = SessionState()
    @Published private(set) var pageIndex = 0
    @Published private(set) var zoomStep = 2
    @Published private(set) var page: DisplayedPage?
    @Published private(set) var runs: [TextRun] = []
    @Published private(set) var pageBlockers: [String] = []
    @Published private(set) var selected: TextRun?
    @Published var editText = ""
    /// The selected text's box, in points from the page image's top-left corner.
    @Published private(set) var selectionBox: CGRect?
    @Published var banner: Banner?
    @Published private(set) var busy = false
    @Published private(set) var busyStatus = ""
    /// Changes whenever the text field should take the keyboard focus.
    @Published private(set) var focusRequest = 0

    /// The pixels per point of the window's screen.
    var backingScale: CGFloat = 2
    private var renderRequest = 0
    private var selectionVersion = 0
    private var signatureWarningAccepted = false

    // MARK: State the views show

    var isOpen: Bool { editor != nil }

    var fileURL: URL? { editor?.filePath.map { URL(fileURLWithPath: $0) } }

    var fileName: String? { editor.map { $0.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled" } }

    var canOpen: Bool { !busy }

    var canUseDocument: Bool { isOpen && !busy }

    var canUndo: Bool { canUseDocument && state.canUndo }

    var canRedo: Bool { canUseDocument && state.canRedo }

    var canZoomIn: Bool { canUseDocument && zoomStep < Self.zoomLevels.count - 1 }

    var canZoomOut: Bool { canUseDocument && zoomStep > 0 }

    private var isEditable: Bool { isOpen && selected != nil && pageBlockers.isEmpty }

    /// Whether the text differs from the selected text, code unit for code unit, as C# compares it.
    private var isChanged: Bool { isEditable && !editText.utf16.elementsEqual((selected?.text ?? "").utf16) }

    var canEditText: Bool { isEditable && !busy }

    var canApply: Bool { isChanged && !busy }

    var canReset: Bool { isChanged && !busy }

    var canDeleteText: Bool { isEditable && !busy }

    var editHint: String {
        selected == nil
            ? "Click any text on the page to select it."
            : "Change the text, then press Return or click Apply. To remove it, click Delete Text."
    }

    var fontInfo: String { selected.map(Self.describe) ?? "" }

    var selectedRunIndex: Int? {
        guard let selected else {
            return nil
        }

        return runs.firstIndex { $0.objectIndex == selected.objectIndex && $0.pageIndex == selected.pageIndex }
    }

    var statusText: String {
        if busy {
            return busyStatus
        }

        guard isOpen else {
            return "Your files stay on this device."
        }

        let zoom = Int((Self.zoomLevels[zoomStep] * 100).rounded())
        return "Page \(pageIndex + 1) of \(state.pageCount) · \(zoom)%" + (state.isModified ? " · Unsaved changes" : "")
    }

    static func listText(_ run: TextRun) -> String {
        let units = Array(run.text.utf16)
        let text = units.count > 80 ? String(decoding: units[0..<79], as: UTF16.self) + "…" : run.text
        return run.isInvisible ? "\(text) (invisible)" : text
    }

    // MARK: Commands

    func openWithPanel() async {
        guard !busy, let url = await presenter?.chooseFileToOpen() else {
            return
        }

        await open(path: url.path)
    }

    func open(path: String) async {
        guard !busy, await confirmDiscardChanges() else {
            return
        }

        var password: String?
        while true {
            setBusy(true, "Opening…")
            let opened: Editor?
            do {
                let attempt = password
                opened = try await perform { try Editor.open(path: path, password: attempt) }
            } catch EditorError.passwordRequired {
                // Ask for the password below, once the busy state is cleared.
                opened = nil
            } catch {
                setBusy(false)
                showMessage(.error, "Couldn't open the file", EditorError.message(of: error))
                return
            }

            setBusy(false)
            if let opened {
                await show(opened)
                return
            }

            password = await presenter?.askPassword(fileName: URL(fileURLWithPath: path).lastPathComponent, retry: password != nil)
            if password == nil {
                return
            }
        }
    }

    private func show(_ opened: Editor) async {
        closeDocument()
        editor = opened
        pageIndex = 0
        signatureWarningAccepted = false
        await refreshState()
        select(nil)
        await renderPage()
        let signed = state.signatureCount > 0
        showMessage(
            signed ? .warning : .informational,
            opened.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Document",
            signed ? "This PDF is digitally signed. Any edit will invalidate its signature." : "Click any text on the page to edit it.")
    }

    /// Closes the document without asking; the window asks first.
    func closeDocument() {
        let closing = editor
        editor = nil
        Self.queue.async { closing?.close() }
    }

    @discardableResult
    func saveAs() async -> Bool {
        guard let editor, !busy else {
            return false
        }

        let current = editor.filePath.map { URL(fileURLWithPath: $0) }
        let suggestedName = current.map { "\($0.deletingPathExtension().lastPathComponent) (edited).pdf" } ?? "document.pdf"
        guard let url = await presenter?.chooseSaveLocation(suggestedName: suggestedName, directory: current?.deletingLastPathComponent()) else {
            return false
        }

        let path = url.path
        setBusy(true, "Saving…")
        do {
            try await perform { try editor.saveAs(path: path) }
        } catch {
            await refreshState()
            setBusy(false)
            showMessage(.error, "Couldn't save", EditorError.message(of: error))
            return false
        }

        await refreshState()
        setBusy(false)
        showMessage(.success, "Saved", path)
        return true
    }

    func changeHistory(undo: Bool) async {
        guard let editor, !busy, undo ? state.canUndo : state.canRedo else {
            return
        }

        let selectedObject = selected?.objectIndex
        setBusy(true, undo ? "Undoing…" : "Redoing…")
        _ = await read { undo ? editor.undo() : editor.redo() }
        await refreshState()
        setBusy(false)

        pageIndex = min(pageIndex, state.pageCount - 1)
        let index = pageIndex
        var reselected: TextRun?
        if let selectedObject {
            reselected = await read { editor.textRun(index, objectIndex: selectedObject) }
        }

        select(reselected)
        banner = nil
        await renderPage()
    }

    func rotatePage() async {
        let index = pageIndex
        await runPageCommand("Rotating…") { try $0.rotatePage(index, quarterTurns: 1) }
    }

    func deletePage() async {
        let index = pageIndex
        guard isOpen, !busy else {
            return
        }

        let choice = await presenter?.ask(
            title: "Delete page \(index + 1)?", message: "You can undo this until you close the document.",
            primary: "Delete", secondary: nil, destructive: true)
        guard choice == .primary else {
            return
        }

        await runPageCommand("Deleting page…") { try $0.deletePage(index) }
    }

    func appendPages() async {
        guard isOpen, !busy, let url = await presenter?.chooseFileToOpen() else {
            return
        }

        let path = url.path
        await runPageCommand("Adding pages…") { try $0.appendDocument(path: path) }
    }

    private func runPageCommand(_ status: String, _ command: @escaping @Sendable (Editor) throws -> EditOutcome) async {
        guard let editor, !busy else {
            return
        }

        select(nil)
        setBusy(true, status)
        let result: EditOutcome
        do {
            result = try await perform { try command(editor) }
        } catch {
            await refreshState()
            setBusy(false)
            showMessage(.error, "Nothing was changed", EditorError.message(of: error))
            return
        }

        await refreshState()
        setBusy(false)
        showResult(result)
        pageIndex = min(pageIndex, state.pageCount - 1)
        await renderPage()
    }

    /// Replaces the selected text with the text field's text, or with nothing to delete it.
    func applyEdit(deleting: Bool) async {
        guard let editor, let run = selected, !busy, deleting ? canDeleteText : canApply else {
            return
        }

        let newText = deleting ? "" : editText
        if state.signatureCount > 0 && !signatureWarningAccepted {
            let choice = await presenter?.ask(
                title: "Edit a signed PDF?", message: "This PDF is digitally signed. Editing it will invalidate the signature.",
                primary: "Edit Anyway", secondary: nil, destructive: true)
            guard choice == .primary else {
                return
            }

            signatureWarningAccepted = true
        }

        setBusy(true, isBlank(newText) ? "Deleting and verifying…" : "Applying and verifying…")
        let result: EditOutcome
        do {
            result = try await perform { try editor.replaceText(run.pageIndex, objectIndex: run.objectIndex, text: newText) }
        } catch {
            await refreshState()
            setBusy(false)
            showMessage(.error, "Nothing was changed", EditorError.message(of: error))
            return
        }

        await refreshState()
        setBusy(false)
        showResult(result)
        if result.status == .applied {
            select(result.textRun)
            await renderPage()
        }
    }

    func reset() {
        editText = selected?.text ?? ""
    }

    func zoom(by delta: Int) async {
        let step = min(max(zoomStep + delta, 0), Self.zoomLevels.count - 1)
        if !busy && step != zoomStep {
            zoomStep = step
            await renderPage()
        }
    }

    func selectPage(_ index: Int) async {
        guard !busy, isOpen, index >= 0, index < state.pageCount, index != pageIndex else {
            return
        }

        pageIndex = index
        select(nil)
        await renderPage()
    }

    func selectRun(at index: Int) {
        guard !busy, runs.indices.contains(index) else {
            return
        }

        select(runs[index])
    }

    /// Selects the text under a point of the page image, in points from its top-left corner.
    func click(at point: CGPoint) async {
        guard let editor, !busy, let page else {
            return
        }

        let (index, width, height) = (pageIndex, page.pixelWidth, page.pixelHeight)
        let x = Int(point.x * page.scale)
        let y = Int(point.y * page.scale)
        let run = await read { editor.hitTest(index, width: width, height: height, x: x, y: y) }
        if editor === self.editor && index == pageIndex && !busy {
            select(run, focusEditor: true)
        }
    }

    func setBackingScale(_ scale: CGFloat) async {
        guard abs(scale - backingScale) > 0.01 else {
            return
        }

        backingScale = scale
        if isOpen {
            await renderPage()
        }
    }

    /// Returns true when it's fine to drop the current document: saved, discarded or unmodified.
    func confirmDiscardChanges() async -> Bool {
        guard let editor, state.isModified else {
            return true
        }

        let name = editor.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "this document"
        let choice = await presenter?.ask(
            title: "Save changes to \(name)?", message: "Your changes will be lost if you don't save them.",
            primary: "Save As…", secondary: "Don't Save", destructive: false)
        switch choice {
        case .primary?:
            return await saveAs()
        case .secondary?:
            return true
        default:
            return false
        }
    }

    // MARK: Drawing and selection

    func renderPage() async {
        guard let editor else {
            page = nil
            return
        }

        let index = pageIndex
        let selection = selected
        let version = selectionVersion
        let scale = backingScale
        let pixelsPerPoint = Self.zoomLevels[zoomStep] * Double(scale)
        renderRequest += 1
        let request = renderRequest
        let rendering: Rendering
        do {
            rendering = try await perform {
                let size = editor.pageSize(index)
                let fit = min(pixelsPerPoint, (maxDisplayPixels / (Double(size.width) * Double(size.height))).squareRoot())
                let width = max(1, Int((Double(size.width) * fit).rounded(.toNearestOrEven)))
                let height = max(1, Int((Double(size.height) * fit).rounded(.toNearestOrEven)))
                let runs = editor.textRuns(index).filter { !isBlank($0.text) }
                let box = selection.flatMap { run in
                    run.pageIndex == index ? editor.mapToPixels(index, rect: run.bounds.inflated(by: 1), width: width, height: height) : nil
                }

                return Rendering(
                    bitmap: try editor.render(index, width: width, height: height),
                    blockers: editor.editBlockers(index),
                    runs: runs,
                    selection: box)
            }
        } catch {
            // A page or document that went away while drawing isn't an error; a newer drawing follows.
            if request == renderRequest && editor === self.editor && index == pageIndex {
                showMessage(.error, "Couldn't draw this page", EditorError.message(of: error))
            }

            return
        }

        guard request == renderRequest, editor === self.editor, index == pageIndex else {
            return
        }

        page = DisplayedPage(image: rendering.bitmap.image, pixelWidth: rendering.bitmap.width, pixelHeight: rendering.bitmap.height, scale: scale)
        pageBlockers = rendering.blockers
        runs = rendering.runs
        if version == selectionVersion {
            selectionBox = rendering.selection.map { Self.points($0, scale) }
        } else {
            updateSelectionBox()
        }
    }

    func select(_ run: TextRun?, focusEditor: Bool = false) {
        selected = run
        selectionVersion += 1
        editText = run?.text ?? ""
        updateSelectionBox()
        if focusEditor && run != nil && canEditText {
            focusRequest += 1
        }
    }

    /// Maps the selection to pixels on the engine queue, then shows its box.
    private func updateSelectionBox() {
        guard let editor, let run = selected, let page, run.pageIndex == pageIndex else {
            selectionBox = nil
            return
        }

        let version = selectionVersion
        let (index, width, height, scale) = (pageIndex, page.pixelWidth, page.pixelHeight, page.scale)
        Task {
            let rect = await read { editor.mapToPixels(index, rect: run.bounds.inflated(by: 1), width: width, height: height) }
            guard let rect, version == selectionVersion, editor === self.editor,
                  width == self.page?.pixelWidth, height == self.page?.pixelHeight else {
                return
            }

            selectionBox = Self.points(rect, scale)
        }
    }

    private static func points(_ pixels: CGRect, _ scale: CGFloat) -> CGRect {
        CGRect(
            x: pixels.minX / scale, y: pixels.minY / scale,
            width: max(2, pixels.width / scale), height: max(2, pixels.height / scale))
    }

    private static func describe(_ run: TextRun) -> String {
        let embedding = run.isFontSubset ? "embedded subset" : run.isFontEmbedded ? "embedded" : "not embedded"
        let details = "Font: \(run.fontName) · \(formatSize(run.fontSize)) pt · \(embedding)"
        return run.isInvisible ? "\(details) · invisible text layer (for example from OCR)" : details
    }

    /// A font size as .NET formats it with "0.#": at most one decimal, rounded half away from zero.
    private static func formatSize(_ size: Float) -> String {
        let tenths = (Double(size) * 10).rounded(.toNearestOrAwayFromZero) / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    // MARK: Messages and state

    private func showResult(_ result: EditOutcome) {
        switch result.status {
        case .applied:
            let body = (result.warnings + result.details).joined(separator: " ")
            showMessage(result.warnings.isEmpty ? .success : .warning, result.message, body.isEmpty ? nil : body)
        case .noChange:
            showMessage(.informational, result.message, nil)
        case .rejected:
            showMessage(.error, "Nothing was changed", result.message)
        }
    }

    private func showMessage(_ severity: Severity, _ title: String, _ message: String?) {
        banner = Banner(severity: severity, title: title, message: message ?? "")
    }

    /// Copies the session's state. Call only when no command is running.
    private func refreshState() async {
        let current = editor
        state = await read { current?.state ?? SessionState() }
    }

    private func setBusy(_ value: Bool, _ status: String = "") {
        busy = value
        if value {
            busyStatus = status
        }
    }

    // MARK: The engine queue

    /// Runs engine work on the engine queue, one call at a time.
    private func perform<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func read<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
