import AppKit

/// Starts PaperKnife's window, opens the PDFs macOS hands the app (Open With in Finder, a
/// double-click, a drop on the Dock icon) or that are named on the command line, and asks before
/// quitting with unsaved changes. Like PaperKnife for Windows, it edits one document at a time.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var launched = false
    private var pendingPath: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        launched = true

        let path = pendingPath ?? CommandLine.arguments.dropFirst().first { $0.lowercased().hasSuffix(".pdf") }
        pendingPath = nil
        if let path {
            controller.open(path)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else {
            return
        }

        if launched, let windowController {
            windowController.open(url.path)
        } else {
            pendingPath = url.path
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windowController, windowController.window?.isVisible == true else {
            return .terminateNow
        }

        Task {
            sender.reply(toApplicationShouldTerminate: await windowController.confirmClose())
        }

        return .terminateLater
    }
}

/// The menu bar. Commands go to the first responder, which is the window's controller unless a
/// text field takes them (Cut, Copy, Paste, Select All, and Undo while typing).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu(title: "Main")
        add(application(), to: menu)
        add(file(), to: menu)
        add(edit(), to: menu)
        add(view(), to: menu)
        add(page(), to: menu)
        let windows = window()
        add(windows, to: menu)
        NSApp.windowsMenu = windows
        return menu
    }

    private static func add(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// An item that isn't shown but whose shortcut works, such as ⌘= for Zoom In.
    private static func hidden(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let menuItem = item(title, action, key, modifiers)
        menuItem.isHidden = true
        menuItem.allowsKeyEquivalentWhenHidden = true
        return menuItem
    }

    private static func application() -> NSMenu {
        let menu = NSMenu(title: "PaperKnife")
        menu.addItem(item("About PaperKnife", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide PaperKnife", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PaperKnife", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
        menu.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s"))
        menu.addItem(hidden("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Add Pages from PDF…", #selector(MainWindowController.appendPages(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(MainWindowController.undoEdit(_:)), "z"))
        menu.addItem(item("Redo", #selector(MainWindowController.redoEdit(_:)), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "+"))
        menu.addItem(hidden("Zoom In", #selector(MainWindowController.zoomIn(_:)), "="))
        menu.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func page() -> NSMenu {
        let menu = NSMenu(title: "Page")
        menu.addItem(item("Rotate Page", #selector(MainWindowController.rotatePage(_:)), "r"))
        menu.addItem(item("Delete Page…", #selector(MainWindowController.deletePage(_:))))
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
