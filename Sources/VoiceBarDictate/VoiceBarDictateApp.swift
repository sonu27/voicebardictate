import AppKit
import SwiftUI

@main
struct VoiceBarDictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("VoiceBar", systemImage: appState.menuBarSymbolName) {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 520)
                .padding()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
