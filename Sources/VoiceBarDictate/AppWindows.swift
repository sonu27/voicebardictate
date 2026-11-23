import AppKit
import Observation
import SwiftUI

// MARK: - Environment actions

private struct OpenSettingsWindowKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

private struct CloseWindowKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Opens the Settings window (closing the menu bar panel first).
    var openSettingsWindow: @MainActor () -> Void {
        get { self[OpenSettingsWindowKey.self] }
        set { self[OpenSettingsWindowKey.self] = newValue }
    }

    /// Closes the AppKit window hosting this view.
    var closeWindow: @MainActor () -> Void {
        get { self[CloseWindowKey.self] }
        set { self[CloseWindowKey.self] = newValue }
    }
}

// MARK: - Menu bar panel access for AppState

/// What `AppState` needs to know about the menu bar panel, without depending on the controller.
@MainActor
enum MenuBarPanel {
    fileprivate(set) static weak var window: NSWindow?
    fileprivate static var closeAction: (() -> Void)?

    static func isPanel(_ window: NSWindow) -> Bool {
        window === self.window
    }

    static func close() {
        closeAction?()
    }
}

// MARK: - Status item

/// The menu bar icon. Left-click toggles the panel; right-click (or Control-click) shows Settings and Quit.
///
/// This replaces SwiftUI's `MenuBarExtra`, which cannot show a right-click menu, and whose window-style panel
/// did not take clicks reliably in an accessory app.
@MainActor
final class StatusItemController: NSObject {
    private(set) static weak var shared: StatusItemController?

    private let appState: AppState
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: PopoverPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var resignKeyObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var panelTopLeft: NSPoint = .zero
    /// When the panel last closed because it lost focus, so the click on the icon that caused it does not reopen it.
    private var lastAutoCloseTime: TimeInterval = 0

    init(appState: AppState, openSettings: @escaping () -> Void) {
        self.appState = appState
        self.openSettings = openSettings
        super.init()
        Self.shared = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("VoiceBar")
        }
        updateIcon()
        MenuBarPanel.closeAction = { [weak self] in self?.closePanel() }
    }

    var isPanelOpen: Bool { panel?.isVisible == true }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if isPanelOpen {
            closePanel()
        } else if ProcessInfo.processInfo.systemUptime - lastAutoCloseTime > 0.3 {
            showPanel()
        }
    }

    // MARK: Icon

    private func updateIcon() {
        withObservationTracking {
            statusItem.button?.image = MenuBarIcon.image(for: appState.menuBarIconState)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    // MARK: Right-click menu

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attaching the menu only for this click shows it under the icon with the usual highlight,
        // while left-clicks keep going to `handleClick`.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    // MARK: Panel

    private func showPanel() {
        let panel = ensurePanel()
        appState.refreshPermissions()
        positionPanel(panel)
        // A non-activating panel takes key focus without activating the app, so the app the user was typing in
        // stays frontmost and receives the paste, and clicks in the panel work on the first try.
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func ensurePanel() -> PopoverPanel {
        if let panel { return panel }

        let root = MenuBarView()
            .environment(appState)
            .environment(\.openSettingsWindow, { [weak self] in
                self?.closePanel()
                self?.openSettings()
            })
        let hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = [.preferredContentSize]

        let panel = PopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 316, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in self?.closePanel() }

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen else { return }
                self.lastAutoCloseTime = ProcessInfo.processInfo.systemUptime
                self.closePanel()
            }
        }
        // The panel grows and shrinks with its content; keep it hanging from the menu bar.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                panel.setFrameTopLeftPoint(self.panelTopLeft)
            }
        }

        self.panel = panel
        self.hostingController = hostingController
        MenuBarPanel.window = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonFrame
        let width = panel.frame.width
        let x = min(max(buttonFrame.minX, visible.minX + 8), visible.maxX - width - 8)
        panelTopLeft = NSPoint(x: x, y: buttonFrame.minY - 6)
        panel.setFrameTopLeftPoint(panelTopLeft)
    }
}

/// A borderless panel that can take key focus, so its buttons and menus respond on the first click.
final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes the panel.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    private let appState: AppState
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView()
            .environment(appState)
            .environment(\.closeWindow, { [weak self] in self?.window?.performClose(nil) })
        let hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VoiceBar Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        return window
    }
}
