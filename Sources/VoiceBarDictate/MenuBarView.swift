import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.statusMessage)
                .font(.headline)

            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(appState.isRecording ? "Stop & Transcribe" : "Start Dictation") {
                appState.toggleFromMenu()
            }
            .keyboardShortcut(.space, modifiers: [.control, .option])
            .disabled(appState.isTranscribing)

            if !appState.lastTranscript.isEmpty {
                Divider()

                Text("Last Transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appState.lastTranscript)
                    .font(.footnote)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Copy Last Transcript") {
                    appState.copyLastTranscriptToClipboard()
                }
            }

            Divider()

            Text("Shortcut: \(appState.hotkeyHint)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Settings...") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
