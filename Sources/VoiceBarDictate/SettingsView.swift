import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var revealAPIKey = false
    @State private var draftAPIKey = ""
    @State private var draftModel: TranscriptionModel = .gptTranscribe
    @State private var draftAPIBaseURL = "https://api.openai.com"
    @State private var draftLanguage = ""
    @State private var draftPrompt = ""
    @State private var draftStartAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VoiceBar Settings")
                .font(.title3)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.headline)

                Picker("Model", selection: $draftModel) {
                    ForEach(TranscriptionModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!appState.canChangeModel)

                if !appState.canChangeModel {
                    Text("You can change the model after dictation finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if draftModel == .appleOnDevice {
                    Text("Requires macOS 26 and a supported Mac. The first use may download a language model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OpenAI API Key")
                    .font(.headline)

                if revealAPIKey {
                    TextField("sk-...", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isUsingDotEnvAPIKey)
                } else {
                    SecureField("sk-...", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isUsingDotEnvAPIKey)
                }

                Toggle("Show API key", isOn: $revealAPIKey)
                    .toggleStyle(.checkbox)

                if appState.isUsingDotEnvAPIKey {
                    Text(".env detected: OPENAI_API_KEY is being used, so this field will not be saved to Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(draftModel == .appleOnDevice)

            VStack(alignment: .leading, spacing: 8) {
                Text("API Base URL")
                    .font(.headline)

                TextField("https://api.openai.com", text: $draftAPIBaseURL)
                    .textFieldStyle(.roundedBorder)

                Text("For EU projects use https://eu.api.openai.com. For US projects use https://us.api.openai.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(draftModel == .appleOnDevice)

            VStack(alignment: .leading, spacing: 8) {
                Text(draftModel == .appleOnDevice ? "Language (optional, e.g. en-GB)" : "Language (optional, e.g. en)")
                    .font(.headline)

                TextField(draftModel == .appleOnDevice ? "System language" : "en", text: $draftLanguage)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt Hint (optional)")
                    .font(.headline)

                TextField("Example: English technical dictation", text: $draftPrompt, axis: .vertical)
                    .lineLimit(2, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(draftModel == .appleOnDevice)

            VStack(alignment: .leading, spacing: 8) {
                Text("Global Shortcut")
                    .font(.headline)

                Text(appState.hotkeyHint)
                    .font(.body.monospaced())

                Button("Request Accessibility Permission") {
                    appState.promptAccessibilityPermission()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Launch")
                    .font(.headline)

                Toggle("Start at login", isOn: $draftStartAtLogin)
                    .toggleStyle(.checkbox)
                    .disabled(!appState.canConfigureLaunchAtLogin)

                if !appState.canConfigureLaunchAtLogin {
                    Text("Launch at login can be enabled after you open the signed .app bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveAndClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!appState.canChangeModel && draftModel != appState.model)
            }
        }
        .onAppear(perform: loadDraftFromAppState)
    }

    private func loadDraftFromAppState() {
        draftAPIKey = appState.apiKey
        draftModel = appState.model
        draftAPIBaseURL = appState.apiBaseURL
        draftLanguage = appState.language
        draftPrompt = appState.prompt
        draftStartAtLogin = appState.launchAtLogin
    }

    private func saveAndClose() {
        guard appState.canChangeModel || draftModel == appState.model else { return }
        let apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.apiKey != apiKey {
            appState.apiKey = apiKey
        }
        appState.setModel(draftModel)

        let baseURL = draftAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.apiBaseURL = baseURL.isEmpty ? "https://api.openai.com" : baseURL

        appState.language = draftLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.setLaunchAtLogin(draftStartAtLogin)
        dismiss()
    }
}
