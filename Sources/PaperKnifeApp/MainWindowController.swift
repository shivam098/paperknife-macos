import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// PaperKnife's window: its toolbar, the commands of the menu bar, and the questions the editor
/// asks, as sheets.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, EditorPresenter {
    let model = EditorModel()
    private var closeConfirmed = false
    private var modelChanges: AnyCancellable?

    private static let frameName = "PaperKnife.Main"

    private struct ToolbarCommand {
        var identifier: NSToolbarItem.Identifier
        var label: String
        var symbol: String
        var action: Selector
        var toolTip: String
    }

    private static let toolbarCommands = [
        ToolbarCommand(identifier: .init("open"), label: "Open", symbol: "folder", action: #selector(MainWindowController.openDocument(_:)), toolTip: "Open a PDF (⌘O)"),
        ToolbarCommand(identifier: .init("save"), label: "Save As", symbol: "square.and.arrow.down", action: #selector(MainWindowController.saveDocumentAs(_:)), toolTip: "Save a copy (⌘S)"),
        ToolbarCommand(identifier: .init("undo"), label: "Undo", symbol: "arrow.uturn.backward", action: #selector(MainWindowController.undoDocumentEdit(_:)), toolTip: "Undo (⌘Z)"),
        ToolbarCommand(identifier: .init("redo"), label: "Redo", symbol: "arrow.uturn.forward", action: #selector(MainWindowController.redoDocumentEdit(_:)), toolTip: "Redo (⇧⌘Z)"),
        ToolbarCommand(identifier: .init("rotate"), label: "Rotate Page", symbol: "rotate.right", action: #selector(MainWindowController.rotatePage(_:)), toolTip: "Rotate the page clockwise (⌘R)"),
        ToolbarCommand(identifier: .init("deletePage"), label: "Delete Page", symbol: "trash", action: #selector(MainWindowController.deletePage(_:)), toolTip: "Delete the page"),
        ToolbarCommand(identifier: .init("append"), label: "Add Pages from PDF", symbol: "doc.badge.plus", action: #selector(MainWindowController.appendPages(_:)), toolTip: "Add the pages of another PDF at the end"),
        ToolbarCommand(identifier: .init("zoomOut"), label: "Zoom Out", symbol: "minus.magnifyingglass", action: #selector(MainWindowController.zoomOut(_:)), toolTip: "Zoom out (⌘-)"),
        ToolbarCommand(identifier: .init("zoomIn"), label: "Zoom In", symbol: "plus.magnifyingglass", action: #selector(MainWindowController.zoomIn(_:)), toolTip: "Zoom in (⌘+)"),
    ]

    private static let toolbarLayout: [NSToolbarItem.Identifier] = [
        .init("open"), .init("save"), .space, .init("undo"), .init("redo"), .space,
        .init("rotate"), .init("deletePage"), .init("append"), .flexibleSpace, .init("zoomOut"), .init("zoomIn"),
    ]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "PaperKnife"
        window.minSize = NSSize(width: 960, height: 600)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(model: model))
        let toolbar = NSToolbar(identifier: "PaperKnife.Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .expanded
        if !window.setFrameUsingName(Self.frameName) {
            // The first time, as large as the design wants but never larger than the screen.
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                let size = NSSize(width: min(1280, visible.width), height: min(820, visible.height))
                window.setFrame(NSRect(origin: visible.origin, size: size), display: false)
            }

            window.center()
        }

        window.setFrameAutosaveName(Self.frameName)
        model.presenter = self
        model.backingScale = window.backingScaleFactor
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            guard let self else {
                return
            }

            // objectWillChange comes before the change; read the model once it's made.
            Task { @MainActor in self.updateWindow() }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(backingPropertiesChanged(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    func open(_ path: String) {
        Task { await model.open(path: path) }
    }

    private func updateWindow() {
        guard let window else {
            return
        }

        window.title = model.fileName ?? "PaperKnife"
        window.representedURL = model.fileURL
        window.isDocumentEdited = model.state.isModified
        window.toolbar?.validateVisibleItems()
    }

    @objc private func backingPropertiesChanged(_ notification: Notification) {
        guard let scale = window?.backingScaleFactor else {
            return
        }

        Task { await model.setBackingScale(scale) }
    }

    // MARK: Commands

    @objc func openDocument(_ sender: Any?) {
        Task { await model.openWithPanel() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        Task { await model.saveAs() }
    }

    @objc func appendPages(_ sender: Any?) {
        Task { await model.appendPages() }
    }

    @objc func rotatePage(_ sender: Any?) {
        Task { await model.rotatePage() }
    }

    @objc func deletePage(_ sender: Any?) {
        Task { await model.deletePage() }
    }

    @objc func zoomIn(_ sender: Any?) {
        Task { await model.zoom(by: 1) }
    }

    @objc func zoomOut(_ sender: Any?) {
        Task { await model.zoom(by: -1) }
    }

    /// Edit > Undo: undoes typing while a text field is being edited, as everywhere in macOS, and
    /// otherwise the last change to the document.
    @objc func undoEdit(_ sender: Any?) {
        if let typing = typingUndoManager, typing.canUndo {
            typing.undo()
        } else {
            undoDocumentEdit(sender)
        }
    }

    @objc func redoEdit(_ sender: Any?) {
        if let typing = typingUndoManager, typing.canRedo {
            typing.redo()
        } else {
            redoDocumentEdit(sender)
        }
    }

    @objc func undoDocumentEdit(_ sender: Any?) {
        Task { await model.changeHistory(undo: true) }
    }

    @objc func redoDocumentEdit(_ sender: Any?) {
        Task { await model.changeHistory(undo: false) }
    }

    /// The undo manager of the text field being edited, if any.
    private var typingUndoManager: UndoManager? {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else {
            return nil
        }

        return editor.undoManager
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }

    private func isEnabled(_ action: Selector?) -> Bool {
        guard let action else {
            return true
        }

        switch action {
        case #selector(openDocument(_:)):
            return model.canOpen
        case #selector(saveDocumentAs(_:)), #selector(appendPages(_:)), #selector(rotatePage(_:)), #selector(deletePage(_:)):
            return model.canUseDocument
        case #selector(undoEdit(_:)):
            return typingUndoManager?.canUndo == true || model.canUndo
        case #selector(redoEdit(_:)):
            return typingUndoManager?.canRedo == true || model.canRedo
        case #selector(undoDocumentEdit(_:)):
            return model.canUndo
        case #selector(redoDocumentEdit(_:)):
            return model.canRedo
        case #selector(zoomIn(_:)):
            return model.canZoomIn
        case #selector(zoomOut(_:)):
            return model.canZoomOut
        default:
            return true
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || (!model.busy && !model.state.isModified) {
            return true
        }

        Task {
            if await confirmClose() {
                window?.close()
            }
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.closeDocument()
    }

    /// Whether the window may close (which quits PaperKnife): nothing would be lost, or the user
    /// agreed to lose it.
    func confirmClose() async -> Bool {
        if closeConfirmed {
            return true
        }

        if model.busy {
            // Never trap the user: an engine call could take very long on a malformed file.
            let choice = await ask(
                title: "PaperKnife is still working",
                message: "Wait for the current action to finish, or quit now. Unsaved changes will be lost if you quit.",
                primary: "Quit Anyway", secondary: nil, destructive: true)
            closeConfirmed = choice == .primary
        } else {
            closeConfirmed = await model.confirmDiscardChanges()
        }

        return closeConfirmed
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarLayout
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarLayout
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let command = Self.toolbarCommands.first(where: { $0.identifier == itemIdentifier }) else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = command.label
        item.paletteLabel = command.label
        item.toolTip = command.toolTip
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.label)
        item.isBordered = true
        item.target = self
        item.action = command.action
        return item
    }

    // MARK: EditorPresenter

    func ask(title: String, message: String, primary: String, secondary: String?, destructive: Bool) async -> DialogChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primary).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        if let secondary {
            alert.addButton(withTitle: secondary)
        }

        switch await present(alert) {
        case .alertFirstButtonReturn:
            return .primary
        case .alertThirdButtonReturn:
            return .secondary
        default:
            return .cancel
        }
    }

    func askPassword(fileName: String, retry: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Password required"
        alert.informativeText = retry ? "That password didn't work. Try again." : "“\(fileName)” is protected with a password."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func chooseFileToOpen() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return await present(panel) == .OK ? panel.url : nil
    }

    func chooseSaveLocation(suggestedName: String, directory: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let directory {
            panel.directoryURL = directory
        }

        return await present(panel) == .OK ? panel.url : nil
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else {
            return .cancel
        }

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard let window else {
            return .cancel
        }

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
