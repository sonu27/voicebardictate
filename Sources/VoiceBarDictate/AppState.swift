import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    @Published var lastTranscript = ""
    @Published var recordingLevel = 0.0
    @Published private(set) var launchAtLogin = false

    @Published var apiKey: String {
        didSet {
            do {
                try settingsStore.saveAPIKey(apiKey)
            } catch {
                setError("Could not save API key: \(error.localizedDescription)")
            }
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

    var isUsingDotEnvAPIKey: Bool {
        settingsStore.isUsingDotEnvAPIKey
    }

    var canConfigureLaunchAtLogin: Bool {
        launchAtLoginService.isSupportedEnvironment
    }

    private let settingsStore: SettingsStore
    private let launchAtLoginService = LaunchAtLoginService()
    private let recorderService = AudioRecorderService()
    private let transcriptionClient = OpenAITranscriptionClient()
    private let textInjector = TextInjector()
    private let hotkeyManager = HotkeyManager()
    private let escapeKeyMonitor = EscapeKeyMonitor()
    private let recordingOverlay = RecordingOverlayController()
    private var recordingLevelTask: Task<Void, Never>?
    private var transcriptionTask: Task<String, Error>?
    private var accessibilityPermissionTask: Task<Void, Never>?
    private var accessibilityStartupTask: Task<Void, Never>?
    private var startupAccessibilityCheckDidRun = false
    private var shouldRelaunchAfterAccessibilityGrant = false

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.apiKey = settingsStore.loadAPIKey()
        self.model = settingsStore.model
        self.apiBaseURL = settingsStore.apiBaseURL
        self.language = settingsStore.language
        self.prompt = settingsStore.prompt
        self.launchAtLogin = settingsStore.startAtLogin

        hotkeyManager.onHotKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleToggleRequest()
            }
        }
        escapeKeyMonitor.onEscapePressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleEscapePressed()
            }
        }
        escapeKeyMonitor.onReturnPressed = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleReturnPressed()
            }
        }

        do {
            try hotkeyManager.registerDefaultShortcut()
        } catch {
            setError("Could not register global shortcut. \(error.localizedDescription)")
        }

        syncLaunchAtLoginPreferenceAtStartup()
        scheduleStartupAccessibilityCheck()
    }

    deinit {
        accessibilityPermissionTask?.cancel()
        accessibilityStartupTask?.cancel()
        recordingLevelTask?.cancel()
        transcriptionTask?.cancel()
    }

    var menuBarSymbolName: String {
        if isRecording {
            return "waveform.circle.fill"
        }
        if isTranscribing {
            return "waveform.circle"
        }
        return "waveform"
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

    func setLaunchAtLogin(_ enabled: Bool) {
        settingsStore.startAtLogin = enabled
        launchAtLogin = enabled

        guard launchAtLoginService.isSupportedEnvironment else { return }

        do {
            try launchAtLoginService.setEnabled(enabled)
            let effectiveState = launchAtLoginService.isEnabled()
            launchAtLogin = effectiveState
            settingsStore.startAtLogin = effectiveState

            if effectiveState == enabled {
                statusMessage = enabled ? "Start at login enabled." : "Start at login disabled."
                return
            }

            setError("Start at login is pending approval in System Settings > General > Login Items.")
        } catch {
            let effectiveState = launchAtLoginService.isEnabled()
            launchAtLogin = effectiveState
            settingsStore.startAtLogin = effectiveState
            setError("Could not update start at login: \(error.localizedDescription)")
        }
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
            escapeKeyMonitor.setCaptureActive(true)
            statusMessage = "Recording..."
            startRecordingLevelUpdates()
        } catch {
            escapeKeyMonitor.setCaptureActive(false)
            setError("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() async {
        do {
            let audioFileURL = try recorderService.stopRecording()
            isRecording = false
            stopRecordingLevelUpdates()
            isTranscribing = true
            recordingOverlay.showTranscribing()
            statusMessage = "Transcribing..."

            defer {
                transcriptionTask = nil
                isTranscribing = false
                escapeKeyMonitor.setCaptureActive(false)
                recordingOverlay.hide()
                try? FileManager.default.removeItem(at: audioFileURL)
            }

            transcriptionTask = Task {
                try await transcriptionClient.transcribe(
                    fileURL: audioFileURL,
                    apiKey: apiKey,
                    baseURL: apiBaseURL,
                    model: model,
                    prompt: prompt,
                    language: language
                )
            }

            guard let transcriptionTask else {
                throw CancellationError()
            }
            let transcript = try await transcriptionTask.value

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
        } catch is CancellationError {
            isRecording = false
            stopRecordingLevelUpdates()
            escapeKeyMonitor.setCaptureActive(false)
            recordingOverlay.hide()
            clearError()
            statusMessage = "Dictation canceled."
        } catch {
            isRecording = false
            stopRecordingLevelUpdates()
            escapeKeyMonitor.setCaptureActive(false)
            recordingOverlay.hide()
            setError("Could not stop and transcribe: \(error.localizedDescription)")
        }
    }

    private func startRecordingLevelUpdates() {
        stopRecordingLevelUpdates()
        recordingLevel = 0
        recordingOverlay.showRecording(level: 0)

        recordingLevelTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let sample = recorderService.currentInputLevel()
                recordingLevel = smoothedLevel(previous: recordingLevel, next: sample)
                recordingOverlay.updateRecordingLevel(recordingLevel)
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
    }

    private func stopRecordingLevelUpdates() {
        recordingLevelTask?.cancel()
        recordingLevelTask = nil
        recordingLevel = 0
    }

    private func smoothedLevel(previous: Double, next: Double) -> Double {
        let rise = 0.6
        let fall = 0.2
        let blend = next > previous ? rise : fall
        return (next * blend) + (previous * (1 - blend))
    }

    private func handleEscapePressed() {
        if isRecording {
            cancelRecording()
            return
        }

        if isTranscribing {
            cancelTranscription()
        }
    }

    private func handleReturnPressed() async {
        guard isRecording, !isTranscribing else { return }
        await stopAndTranscribe()
    }

    private func cancelRecording() {
        if let audioURL = try? recorderService.stopRecording() {
            try? FileManager.default.removeItem(at: audioURL)
        }

        isRecording = false
        stopRecordingLevelUpdates()
        escapeKeyMonitor.setCaptureActive(false)
        recordingOverlay.hide()
        clearError()
        statusMessage = "Dictation canceled."
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        statusMessage = "Canceling..."
    }

    private func clearError() {
        errorMessage = nil
    }

    private func setError(_ message: String) {
        errorMessage = message
        statusMessage = message
    }

    private func scheduleStartupAccessibilityCheck() {
        accessibilityStartupTask?.cancel()
        accessibilityStartupTask = Task { @MainActor [weak self] in
            // Trigger prompt only after launch settles, so macOS can register the app properly.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.runStartupAccessibilityCheckIfNeeded()
        }
    }

    private func runStartupAccessibilityCheckIfNeeded() {
        guard !startupAccessibilityCheckDidRun else { return }
        startupAccessibilityCheckDidRun = true

        guard !textInjector.hasAccessibilityPermission(promptIfNeeded: false) else { return }

        shouldRelaunchAfterAccessibilityGrant = true
        let hasPermissionAfterPrompt = textInjector.hasAccessibilityPermission(promptIfNeeded: true)
        if hasPermissionAfterPrompt {
            relaunchAfterAccessibilityGrant()
            return
        }

        setError("Grant Accessibility permission in System Settings > Privacy & Security > Accessibility. VoiceBarDictate will restart automatically after access is enabled.")
        monitorAccessibilityPermissionUntilGranted()
    }

    private func monitorAccessibilityPermissionUntilGranted() {
        accessibilityPermissionTask?.cancel()
        accessibilityPermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                if textInjector.hasAccessibilityPermission(promptIfNeeded: false) {
                    relaunchAfterAccessibilityGrant()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func relaunchAfterAccessibilityGrant() {
        guard shouldRelaunchAfterAccessibilityGrant else { return }
        shouldRelaunchAfterAccessibilityGrant = false
        accessibilityPermissionTask?.cancel()
        clearError()
        statusMessage = "Accessibility enabled. Restarting..."

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
            do {
                try process.run()
                NSApp.terminate(nil)
            } catch {
                setError("Accessibility enabled. Please restart the app manually. \(error.localizedDescription)")
            }
            return
        }

        let process = Process()
        process.executableURL = executableURL
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            setError("Accessibility enabled. Please restart the app manually. \(error.localizedDescription)")
        }
    }

    private func syncLaunchAtLoginPreferenceAtStartup() {
        guard launchAtLoginService.isSupportedEnvironment else { return }

        do {
            try launchAtLoginService.setEnabled(launchAtLogin)
            let effectiveState = launchAtLoginService.isEnabled()
            launchAtLogin = effectiveState
            settingsStore.startAtLogin = effectiveState
        } catch {
            let effectiveState = launchAtLoginService.isEnabled()
            launchAtLogin = effectiveState
            settingsStore.startAtLogin = effectiveState
        }
    }
}
