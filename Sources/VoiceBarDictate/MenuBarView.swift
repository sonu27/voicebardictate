import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.statusMessage)

        if let errorMessage = appState.errorMessage {
            Text("Error: \(errorMessage)")
                .foregroundStyle(.red)
        }

        Button(appState.isRecording ? "Stop & Transcribe" : "Start Dictation") {
            appState.toggleFromMenu()
        }
        .keyboardShortcut(.space, modifiers: [.control, .option])
        .disabled(appState.isTranscribing)

        if !appState.lastTranscript.isEmpty {
            Divider()
            Text("Last Transcript")
            Text(transcriptPreview(appState.lastTranscript))

            Button("Copy Last Transcript") {
                appState.copyLastTranscriptToClipboard()
            }
        }

        Divider()

        Text("Shortcut: \(appState.hotkeyHint)")

        Divider()

        Button("Open Debug Log") {
            appState.openDebugLogInFinder()
        }

        Button("Copy Debug Log Path") {
            appState.copyDebugLogPathToClipboard()
        }

        Button("Settings...") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }

    private func transcriptPreview(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 120
        guard trimmed.count > maxLength else {
            return trimmed
        }

        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<endIndex]) + "..."
    }
}
