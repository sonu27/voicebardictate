import AppKit

/// AppKit entry point. The app is a menu bar utility, so it owns its status item, panel, and Settings window
/// directly instead of using SwiftUI scenes (`MenuBarExtra` cannot show a right-click menu).
@main
enum VoiceBarDictateMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The app is dark-only (see docs/design). This covers every window, menu, and system control.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let appState = AppState()
        let settings = SettingsWindowController(appState: appState)
        self.appState = appState
        settingsWindowController = settings
        statusItemController = StatusItemController(appState: appState) { settings.show() }
        NSApp.mainMenu = makeMainMenu()

        #if DEBUG
        DebugSnapshots.appState = appState
        DebugSnapshots.writeOverlayStates()
        DebugSnapshots.watchForCommands()
        #endif
    }

    @objc private func showSettings() {
        settingsWindowController?.show()
    }

    /// Never shown (the app has no Dock icon or menu bar of its own), but it is what makes ⌘, ⌘Q, ⌘W and the
    /// standard editing shortcuts (⌘C, ⌘V, ⌘A, ⌘Z) work in the Settings window.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit VoiceBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        mainMenu.addItem(submenu: appMenu, title: "VoiceBar")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        mainMenu.addItem(submenu: windowMenu, title: "Window")

        return mainMenu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
