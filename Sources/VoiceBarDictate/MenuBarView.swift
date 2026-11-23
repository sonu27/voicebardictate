import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.statusMessage)

        if let errorMessage = appState.errorMessage, errorMessage != appState.statusMessage {
            Text("Error: \(errorMessage)")
                .foregroundStyle(.red)
        }

        if let progress = appState.appleModelDownloadProgress {
            Text("Downloading Apple speech model: \(Int((progress * 100).rounded()))%")
        }

        Button(appState.isRecording ? "Stop & Transcribe" : "Start Dictation") {
            appState.toggleFromMenu()
        }
        .keyboardShortcut(appState.hotkey.menuKeyboardShortcut)
        .disabled(appState.phase == .starting || appState.isTranscribing)

        if !appState.lastTranscript.isEmpty {
            Divider()
            Text("Last Transcript")
            Text(transcriptPreview(appState.lastTranscript))

            Button("Copy Last Transcript") {
                appState.copyLastTranscriptToClipboard()
            }
        }

        Divider()

        Text("Shortcut: \(appState.hotkeyHint)\(appState.hotkeyMode == .hold ? " (hold)" : "")")

        Button("Settings...") {
            NSApp.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
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
