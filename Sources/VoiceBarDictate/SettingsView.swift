import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SettingsDraft(
        apiKey: "",
        model: .gptTranscribe,
        openAIModelID: TranscriptionModel.defaultOpenAIModelID,
        apiBaseURL: SettingsStore.defaultAPIBaseURL,
        language: "",
        prompt: "",
        startAtLogin: false,
        hotkey: .default,
        hotkeyMode: .toggle
    )
    @State private var revealAPIKey = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                transcriptionSection
                if draft.model == .gptTranscribe {
                    openAISection
                }
                languageSection
                shortcutSection
                launchSection
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    appState.saveSettings(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!appState.canChangeModel && draft.model != appState.model)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 4)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            draft = appState.currentSettings
        }
    }

    private var transcriptionSection: some View {
        Section {
            Picker("Engine", selection: $draft.model) {
                ForEach(TranscriptionModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .disabled(!appState.canChangeModel)
        } header: {
            Text("Transcription")
        } footer: {
            if !appState.canChangeModel {
                footnote("You can change the engine after dictation finishes.")
            } else if draft.model == .appleOnDevice {
                footnote("Runs locally with live results while you speak. Requires macOS 26 and a supported Mac. The language model downloads automatically the first time.")
            }
        }
    }

    private var openAISection: some View {
        Section {
            Group {
                if revealAPIKey {
                    TextField("API Key", text: $draft.apiKey, prompt: Text("sk-..."))
                } else {
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("sk-..."))
                }
            }
            .disabled(appState.isUsingDotEnvAPIKey)

            Toggle("Show API key", isOn: $revealAPIKey)

            TextField("Model", text: $draft.openAIModelID, prompt: Text(TranscriptionModel.defaultOpenAIModelID))

            TextField("API Base URL", text: $draft.apiBaseURL, prompt: Text(SettingsStore.defaultAPIBaseURL))

            TextField("Prompt Hint", text: $draft.prompt, prompt: Text("Example: English technical dictation"), axis: .vertical)
                .lineLimit(2, reservesSpace: true)
        } header: {
            Text("OpenAI")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if appState.isUsingDotEnvAPIKey {
                    footnote(".env detected (debug build): OPENAI_API_KEY is being used, so this field will not be saved to Keychain.")
                }
                footnote("For EU projects use https://eu.api.openai.com. For US projects use https://us.api.openai.com.")
            }
        }
    }

    private var languageSection: some View {
        Section {
            TextField(
                "Language",
                text: $draft.language,
                prompt: Text(draft.model == .appleOnDevice ? "System language" : "Auto-detect")
            )
        } footer: {
            footnote(draft.model == .appleOnDevice ? "Optional, for example en-GB." : "Optional, for example en.")
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent("Global Shortcut") {
                ShortcutRecorder(hotkey: $draft.hotkey)
            }

            Picker("Behavior", selection: $draft.hotkeyMode) {
                ForEach(HotkeyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            LabeledContent("Accessibility") {
                Button("Request Permission") {
                    appState.promptAccessibilityPermission()
                }
            }
        } header: {
            Text("Shortcut")
        } footer: {
            footnote("While dictating, press Escape to cancel or Return to finish.")
        }
    }

    private var launchSection: some View {
        Section {
            Toggle("Start at login", isOn: $draft.startAtLogin)
                .disabled(!appState.canConfigureLaunchAtLogin)
        } footer: {
            if !appState.canConfigureLaunchAtLogin {
                footnote("Launch at login can be enabled after you open the signed .app bundle.")
            }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A button that records the next key combination pressed and turns it into a `Hotkey`.
private struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey
    @Environment(AppState.self) private var appState

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(isRecording ? "Press shortcut..." : hotkey.displayString) {
                    isRecording ? stopRecording() : startRecording()
                }
                .font(.body.monospaced())

                if hotkey != .default, !isRecording {
                    Button("Reset") {
                        hotkey = .default
                        validationMessage = nil
                    }
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        validationMessage = nil
        isRecording = true
        appState.beginShortcutCapture()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 /* Escape */ && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
                return nil
            }

            switch Hotkey.make(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                characters: event.characters(byApplyingModifiers: [])
            ) {
            case .success(let recorded):
                hotkey = recorded
                stopRecording()
            case .failure(let error):
                validationMessage = error.localizedDescription
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        appState.endShortcutCapture()
    }
}
