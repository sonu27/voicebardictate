import AppKit
import SwiftUI

@main
struct VoiceBarDictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("VoiceBar", systemImage: appState.menuBarSymbolName) {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)

        // `Window` is single-instance, unlike `WindowGroup`, so Settings cannot be opened twice.
        Window("VoiceBar Settings", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
