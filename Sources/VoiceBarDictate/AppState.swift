import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    @Published var lastTranscript = ""

    @Published var apiKey: String {
        didSet {
            settingsStore.saveAPIKey(apiKey)
        }
    }

    @Published var model: String {
        didSet {
            settingsStore.model = model
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            settingsStore.apiBaseURL = apiBaseURL
        }
    }

    @Published var language: String {
        didSet {
            settingsStore.language = language
        }
    }

    @Published var prompt: String {
        didSet {
            settingsStore.prompt = prompt
        }
    }

    let availableModels = [
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
        "whisper-1"
    ]

    let hotkeyHint = "Control + Option + Space"

    private let settingsStore: SettingsStore
    private let recorderService = AudioRecorderService()
    private let transcriptionClient = OpenAITranscriptionClient()
    private let textInjector = TextInjector()
    private let hotkeyManager = HotkeyManager()

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.apiKey = settingsStore.loadAPIKey()
        self.model = settingsStore.model
        self.apiBaseURL = settingsStore.apiBaseURL
        self.language = settingsStore.language
        self.prompt = settingsStore.prompt

        hotkeyManager.onHotKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleToggleRequest()
            }
        }

        do {
            try hotkeyManager.registerDefaultShortcut()
        } catch {
            setError("Could not register global shortcut. \(error.localizedDescription)")
        }
    }

    var menuBarSymbolName: String {
        if isRecording {
            return "waveform.circle.fill"
        }
        if isTranscribing {
            return "hourglass.circle.fill"
        }
        return "mic.circle"
    }

    func toggleFromMenu() {
        Task {
            await handleToggleRequest()
        }
    }

    func promptAccessibilityPermission() {
        if textInjector.hasAccessibilityPermission(promptIfNeeded: true) {
            statusMessage = "Accessibility permission is enabled."
            clearError()
        } else {
            setError("Enable Accessibility for this app in System Settings > Privacy & Security > Accessibility.")
        }
    }

    func copyLastTranscriptToClipboard() {
        guard !lastTranscript.isEmpty else { return }
        TextInjector.copyToClipboard(lastTranscript)
        statusMessage = "Last transcript copied."
    }

    private func handleToggleRequest() async {
        if isTranscribing {
            return
        }

        if isRecording {
            await stopAndTranscribe()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        clearError()

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Add your OpenAI API key in Settings before recording.")
            return
        }

        let microphonePermission = await recorderService.requestPermission()
        guard microphonePermission else {
            setError("Microphone permission is not granted. Enable it in System Settings > Privacy & Security > Microphone.")
            return
        }

        do {
            _ = try recorderService.startRecording()
            isRecording = true
            statusMessage = "Recording..."
        } catch {
            setError("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() async {
        do {
            let audioFileURL = try recorderService.stopRecording()
            isRecording = false
            isTranscribing = true
            statusMessage = "Transcribing..."

            defer {
                isTranscribing = false
                try? FileManager.default.removeItem(at: audioFileURL)
            }

            let transcript = try await transcriptionClient.transcribe(
                fileURL: audioFileURL,
                apiKey: apiKey,
                baseURL: apiBaseURL,
                model: model,
                prompt: prompt,
                language: language
            )

            let normalizedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                statusMessage = "No speech detected."
                return
            }

            lastTranscript = normalizedText

            do {
                try textInjector.inject(text: normalizedText)
                clearError()
                statusMessage = "Transcribed and pasted."
            } catch {
                setError("Transcribed but failed to paste automatically: \(error.localizedDescription)")
            }
        } catch {
            isRecording = false
            setError("Could not stop and transcribe: \(error.localizedDescription)")
        }
    }

    private func clearError() {
        errorMessage = nil
    }

    private func setError(_ message: String) {
        errorMessage = message
        statusMessage = message
    }
}
