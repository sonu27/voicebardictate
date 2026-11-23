import AppKit
import Foundation
import Observation
import Speech

/// Where the dictation pipeline is. A single value replaces separate flags that could disagree.
enum DictationPhase: Equatable {
    case idle
    /// Checking the API key, microphone permission, and language before capture begins.
    case starting
    case recording
    case transcribing
}

/// Editable settings, saved together from the Settings window.
struct SettingsDraft: Equatable {
    var apiKey: String
    var model: TranscriptionModel
    var openAIModelID: String
    var apiBaseURL: String
    var language: String
    var prompt: String
    var startAtLogin: Bool
    var hotkey: Hotkey
    var hotkeyMode: HotkeyMode
}

@Observable
@MainActor
final class AppState {
    private(set) var phase: DictationPhase = .idle {
        didSet {
            // Escape cancels and Return finishes while dictation is in progress.
            escapeKeyMonitor.setCaptureActive(phase != .idle)
        }
    }
    private(set) var statusMessage = "Ready"
    private(set) var errorMessage: String?
    private(set) var lastTranscript = ""
    private(set) var launchAtLogin = false
    /// 0...1 while the Apple On-Device language model downloads, otherwise nil.
    private(set) var appleModelDownloadProgress: Double?

    private(set) var apiKey: String
    private(set) var model: TranscriptionModel
    private(set) var openAIModelID: String
    private(set) var apiBaseURL: String
    private(set) var language: String
    private(set) var prompt: String
    private(set) var hotkey: Hotkey
    private(set) var hotkeyMode: HotkeyMode

    var isRecording: Bool { phase == .recording }
    var isTranscribing: Bool { phase == .transcribing }
    var canChangeModel: Bool { phase == .idle }
    var hotkeyHint: String { hotkey.displayString }

    var isUsingDotEnvAPIKey: Bool {
        settingsStore.isUsingDotEnvAPIKey
    }

    var canConfigureLaunchAtLogin: Bool {
        launchAtLoginService.isSupportedEnvironment
    }

    var currentSettings: SettingsDraft {
        SettingsDraft(
            apiKey: apiKey,
            model: model,
            openAIModelID: openAIModelID,
            apiBaseURL: apiBaseURL,
            language: language,
            prompt: prompt,
            startAtLogin: launchAtLogin,
            hotkey: hotkey,
            hotkeyMode: hotkeyMode
        )
    }

    var menuBarSymbolName: String {
        switch phase {
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "waveform.circle"
        case .idle, .starting: return "waveform"
        }
    }

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let launchAtLoginService = LaunchAtLoginService()
    @ObservationIgnored private let recorderService = AudioRecorderService()
    @ObservationIgnored private let transcriptionClient = OpenAITranscriptionClient()
    @ObservationIgnored private let textInjector = TextInjector()
    @ObservationIgnored private let hotkeyManager = HotkeyManager()
    @ObservationIgnored private let escapeKeyMonitor = EscapeKeyMonitor()
    @ObservationIgnored private let recordingOverlay = RecordingOverlayController()

    @ObservationIgnored private var recordingLevelTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<String, Error>?
    @ObservationIgnored private var activeRecording: ActiveRecording?
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var isHoldingHotkey = false
    @ObservationIgnored private var recordingLevel = 0.0
    @ObservationIgnored private var appleModelDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var accessibilityPermissionTask: Task<Void, Never>?
    @ObservationIgnored private var accessibilityStartupTask: Task<Void, Never>?
    @ObservationIgnored private var startupAccessibilityCheckDidRun = false
    @ObservationIgnored private var isWaitingForAccessibilityGrant = false

    private enum ActiveRecording {
        /// Audio is written to a file and uploaded after recording stops.
        case openAI
        /// Audio streams into a live session; `startTask` attaches the session to the recorder.
        case live(any LiveTranscriptionSession, startTask: Task<Void, Error>)
    }

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.apiKey = settingsStore.loadAPIKey()
        self.model = settingsStore.model
        self.openAIModelID = settingsStore.openAIModelID
        self.apiBaseURL = settingsStore.apiBaseURL
        self.language = settingsStore.language
        self.prompt = settingsStore.prompt
        self.launchAtLogin = settingsStore.startAtLogin
        self.hotkey = settingsStore.hotkey
        self.hotkeyMode = settingsStore.hotkeyMode

        // Carbon and the event tap deliver on the main thread, so handle them synchronously and in order.
        hotkeyManager.onHotKeyPressed = { [weak self] in
            MainActor.assumeIsolated { self?.handleHotkeyPressed() }
        }
        hotkeyManager.onHotKeyReleased = { [weak self] in
            MainActor.assumeIsolated { self?.handleHotkeyReleased() }
        }
        escapeKeyMonitor.onEscapePressed = { [weak self] in
            MainActor.assumeIsolated { self?.handleEscapePressed() }
        }
        escapeKeyMonitor.onReturnPressed = { [weak self] in
            MainActor.assumeIsolated { self?.handleReturnPressed() }
        }
        recorderService.onInputInterrupted = { [weak self] in
            self?.handleInputInterrupted()
        }

        registerHotkey()

        if let legacyModelID = settingsStore.migratedLegacyModelID {
            statusMessage = "\(legacyModelID) was retired. Now using \(openAIModelID)."
        }

        syncLaunchAtLoginPreferenceAtStartup()
        scheduleStartupAccessibilityCheck()

        if model == .appleOnDevice {
            prepareAppleModelIfNeeded()
        }
    }

    // MARK: - Menu and Settings actions

    func toggleFromMenu() {
        handleToggleRequest()
    }

    func saveSettings(_ draft: SettingsDraft) {
        let trimmedKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey != apiKey {
            do {
                try settingsStore.saveAPIKey(trimmedKey)
                apiKey = trimmedKey
            } catch {
                setError("Could not save API key: \(error.localizedDescription)")
            }
        }

        let previousModel = model
        let previousLanguage = language

        if canChangeModel, draft.model != model {
            model = draft.model
            settingsStore.model = draft.model
        }

        let modelID = draft.openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        openAIModelID = modelID.isEmpty ? TranscriptionModel.defaultOpenAIModelID : modelID
        settingsStore.openAIModelID = openAIModelID

        let baseURL = draft.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        apiBaseURL = baseURL.isEmpty ? SettingsStore.defaultAPIBaseURL : baseURL
        settingsStore.apiBaseURL = apiBaseURL

        language = draft.language.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.language = language

        // Each language has its own on-device model, so fetch it as soon as it is chosen.
        if model == .appleOnDevice, previousModel != model || previousLanguage != language {
            prepareAppleModelIfNeeded()
        }

        prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.prompt = prompt

        hotkeyMode = draft.hotkeyMode
        settingsStore.hotkeyMode = draft.hotkeyMode

        if draft.hotkey != hotkey {
            setHotkey(draft.hotkey)
        }

        if draft.startAtLogin != launchAtLogin {
            setLaunchAtLogin(draft.startAtLogin)
        }
    }

    /// Stops the global shortcut from firing while the Settings window records a new one.
    func beginShortcutCapture() {
        hotkeyManager.unregister()
    }

    func endShortcutCapture() {
        registerHotkey()
    }

    func promptAccessibilityPermission() {
        if textInjector.hasAccessibilityPermission(promptIfNeeded: true) {
            escapeKeyMonitor.enableExclusiveCaptureIfPossible()
            statusMessage = "Accessibility permission is enabled."
            clearError()
        } else {
            setError("Enable Accessibility for this app in System Settings > Privacy & Security > Accessibility.")
            monitorAccessibilityPermissionUntilGranted()
        }
    }

    func copyLastTranscriptToClipboard() {
        guard !lastTranscript.isEmpty else { return }
        TextInjector.copyToClipboard(lastTranscript)
        statusMessage = "Last transcript copied."
    }

    private func setHotkey(_ newHotkey: Hotkey) {
        let previous = hotkey
        do {
            try hotkeyManager.register(newHotkey)
            hotkey = newHotkey
            settingsStore.hotkey = newHotkey
            statusMessage = "Shortcut set to \(newHotkey.displayString)."
        } catch {
            try? hotkeyManager.register(previous)
            setError(error.localizedDescription)
        }
    }

    private func registerHotkey() {
        do {
            try hotkeyManager.register(hotkey)
        } catch {
            setError("Could not register global shortcut. \(error.localizedDescription)")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
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

    // MARK: - Shortcut handling

    private func handleHotkeyPressed() {
        switch hotkeyMode {
        case .toggle:
            handleToggleRequest()
        case .hold:
            guard phase == .idle else { return }
            isHoldingHotkey = true
            startRecording()
        }
    }

    private func handleHotkeyReleased() {
        guard hotkeyMode == .hold, isHoldingHotkey else { return }
        isHoldingHotkey = false

        switch phase {
        case .recording:
            Task { await stopAndTranscribe() }
        case .starting:
            // Released before capture began: treat it as a cancelled tap.
            cancelStart()
        case .idle, .transcribing:
            break
        }
    }

    private func handleToggleRequest() {
        switch phase {
        case .idle:
            startRecording()
        case .recording:
            Task { await stopAndTranscribe() }
        case .starting, .transcribing:
            break
        }
    }

    private func handleEscapePressed() {
        switch phase {
        case .starting:
            cancelStart()
        case .recording:
            cancelRecording()
        case .transcribing:
            cancelTranscription()
        case .idle:
            break
        }
    }

    private func handleReturnPressed() {
        guard phase == .recording else { return }
        Task { await stopAndTranscribe() }
    }

    private func handleInputInterrupted() {
        guard phase == .recording else { return }
        Task {
            await stopAndTranscribe()
            if errorMessage == nil {
                statusMessage = "Audio input changed, so dictation stopped. \(statusMessage)"
            }
        }
    }

    // MARK: - Recording

    /// Moves to `.starting` synchronously, so a key release or Escape that arrives during the
    /// async checks below always sees the right phase.
    private func startRecording() {
        guard phase == .idle else { return }
        clearError()
        phase = .starting
        startGeneration &+= 1
        let generation = startGeneration
        Task { await performStart(generation: generation) }
    }

    private func isCurrentStart(_ generation: Int) -> Bool {
        phase == .starting && startGeneration == generation
    }

    private func cancelStart() {
        guard phase == .starting else { return }
        startGeneration &+= 1
        phase = .idle
        recordingOverlay.hide()
        statusMessage = "Dictation canceled."
    }

    private func failStart(_ message: String) {
        phase = .idle
        recordingOverlay.hide()
        setError(message)
    }

    private func performStart(generation: Int) async {
        let selectedModel = model
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModel == .appleOnDevice || !key.isEmpty else {
            failStart("Add your OpenAI API key in Settings before recording.")
            return
        }

        let microphonePermission = await recorderService.requestPermission()
        guard isCurrentStart(generation) else { return }
        guard microphonePermission else {
            failStart("Microphone permission is not granted. Enable it in System Settings > Privacy & Security > Microphone.")
            return
        }

        do {
            switch selectedModel {
            case .gptTranscribe:
                _ = try recorderService.startRecording(writesFile: true)
                activeRecording = .openAI
            case .appleOnDevice:
                guard #available(macOS 26.0, *) else { throw AppleTranscriptionError.unavailable }
                guard let recording = try await startAppleRecording(language: language, generation: generation) else {
                    return
                }
                activeRecording = recording
            }
        } catch {
            guard isCurrentStart(generation) else { return }
            failStart("Could not start recording: \(error.localizedDescription)")
            return
        }

        phase = .recording
        statusMessage = "Recording..."
        startRecordingLevelUpdates()
    }

    /// Returns nil when the start was abandoned (cancelled, or the language model still needs downloading).
    @available(macOS 26.0, *)
    private func startAppleRecording(language: String, generation: Int) async throws -> ActiveRecording? {
        let locale = try await AppleSpeechModel.locale(for: language)
        guard isCurrentStart(generation) else { return nil }

        // The model must be installed before live audio can be analyzed. Download it in the background
        // rather than leaving the user talking into a session that cannot start yet.
        if appleModelDownloadTask != nil {
            reportAppleModelDownloadInProgress()
            return nil
        }
        if let request = try await AppleSpeechModel.installationRequest(for: locale) {
            guard isCurrentStart(generation) else { return nil }
            startAppleModelDownload(request, announceCompletion: true)
            reportAppleModelDownloadInProgress()
            return nil
        }
        guard isCurrentStart(generation) else { return nil }

        // Start capture first and hold the audio, so the first words are not lost while the analyzer warms up.
        let sink = try recorderService.startRecording(writesFile: false, buffersUntilHandlerAttached: true)
        let session = AppleLiveTranscription(locale: locale)
        let startTask = Task { [weak self] in
            do {
                let handler = try await session.start(inputFormat: sink.inputFormat) { text in
                    self?.recordingOverlay.updateLiveText(text)
                }
                sink.attachBufferHandler(handler)
            } catch {
                self?.failLiveSession(session, error: error)
                throw error
            }
        }
        return .live(session, startTask: startTask)
    }

    private func failLiveSession(_ session: any LiveTranscriptionSession, error: Error) {
        guard case .live(let active, _) = activeRecording, active === session else { return }
        cancelRecording()
        setError("Apple On-Device could not start: \(error.localizedDescription)")
    }

    private func stopAndTranscribe() async {
        guard phase == .recording, let recording = activeRecording else { return }
        activeRecording = nil
        stopRecordingLevelUpdates()
        phase = .transcribing
        recordingOverlay.showTranscribing()
        statusMessage = "Transcribing..."

        let audioFileURL = recorderService.stopRecording()
        defer {
            transcriptionTask = nil
            phase = .idle
            recordingOverlay.hide()
            if let audioFileURL {
                try? FileManager.default.removeItem(at: audioFileURL)
            }
        }

        let task: Task<String, Error>
        switch recording {
        case .openAI:
            guard let audioFileURL else {
                setError("Could not stop and transcribe: no audio was recorded.")
                return
            }
            let client = transcriptionClient
            let apiKey = apiKey
            let baseURL = apiBaseURL
            let modelID = openAIModelID
            let prompt = prompt
            let language = language
            task = Task {
                try await client.transcribe(
                    fileURL: audioFileURL,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: modelID,
                    prompt: prompt,
                    language: language
                )
            }
        case .live(let session, let startTask):
            task = Task {
                try await startTask.value
                return try await session.finish()
            }
        }
        transcriptionTask = task

        do {
            let transcript = try await task.value
            guard !task.isCancelled else { throw CancellationError() }

            let normalizedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                statusMessage = "No speech detected."
                return
            }

            lastTranscript = normalizedText

            do {
                try await textInjector.inject(text: normalizedText)
                clearError()
                statusMessage = "Transcribed and pasted."
            } catch {
                setError("Transcribed but failed to paste automatically: \(error.localizedDescription)")
            }
        } catch {
            if error is CancellationError || task.isCancelled {
                clearError()
                statusMessage = "Dictation canceled."
            } else {
                setError("Could not stop and transcribe: \(error.localizedDescription)")
            }
        }
    }

    private func cancelRecording() {
        guard let recording = activeRecording else { return }
        activeRecording = nil

        if let audioURL = recorderService.stopRecording() {
            try? FileManager.default.removeItem(at: audioURL)
        }
        if case .live(let session, let startTask) = recording {
            startTask.cancel()
            Task { await session.cancel() }
        }

        stopRecordingLevelUpdates()
        phase = .idle
        recordingOverlay.hide()
        clearError()
        statusMessage = "Dictation canceled."
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        statusMessage = "Canceling..."
    }

    private func startRecordingLevelUpdates() {
        stopRecordingLevelUpdates()
        recordingOverlay.showRecording(level: 0)

        recordingLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = recorderService.currentInputLevel()
                recordingLevel = Self.smoothedLevel(previous: recordingLevel, next: sample)
                recordingOverlay.updateRecordingLevel(recordingLevel)
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private func stopRecordingLevelUpdates() {
        recordingLevelTask?.cancel()
        recordingLevelTask = nil
        recordingLevel = 0
    }

    /// Rises quickly and falls slowly so the meter reads as speech, not noise.
    nonisolated static func smoothedLevel(previous: Double, next: Double) -> Double {
        let rise = 0.6
        let fall = 0.2
        let blend = next > previous ? rise : fall
        return (next * blend) + (previous * (1 - blend))
    }

    // MARK: - Apple On-Device model

    /// Downloads the language model for the current language ahead of time, so the first dictation can start at once.
    private func prepareAppleModelIfNeeded() {
        guard #available(macOS 26.0, *), appleModelDownloadTask == nil else { return }
        let language = language
        Task {
            guard
                let locale = try? await AppleSpeechModel.locale(for: language),
                let request = try? await AppleSpeechModel.installationRequest(for: locale),
                appleModelDownloadTask == nil
            else {
                return
            }
            startAppleModelDownload(request, announceCompletion: false)
            statusMessage = "Downloading the Apple On-Device language model..."
        }
    }

    @available(macOS 26.0, *)
    private func startAppleModelDownload(_ request: AssetInstallationRequest, announceCompletion: Bool) {
        appleModelDownloadProgress = 0
        appleModelDownloadTask = Task {
            let progressTask = Task {
                while !Task.isCancelled {
                    appleModelDownloadProgress = request.progress.fractionCompleted
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer {
                progressTask.cancel()
                appleModelDownloadProgress = nil
                appleModelDownloadTask = nil
            }

            do {
                try await request.downloadAndInstall()
                statusMessage = "Apple On-Device is ready."
                if announceCompletion {
                    recordingOverlay.showMessage("Apple On-Device is ready. Press \(hotkey.displayString) to dictate.")
                }
            } catch {
                setError("Could not download the Apple On-Device language model: \(error.localizedDescription)")
            }
        }
    }

    private func reportAppleModelDownloadInProgress() {
        let percent = Int(((appleModelDownloadProgress ?? 0) * 100).rounded())
        let message = "Downloading the Apple On-Device language model (\(percent)%). Try again when it finishes."
        phase = .idle
        statusMessage = message
        recordingOverlay.showMessage(message)
    }

    // MARK: - Errors

    private func clearError() {
        errorMessage = nil
    }

    private func setError(_ message: String) {
        errorMessage = message
        statusMessage = message
    }

    // MARK: - Accessibility

    private func scheduleStartupAccessibilityCheck() {
        accessibilityStartupTask?.cancel()
        accessibilityStartupTask = Task { [weak self] in
            // Trigger prompt only after launch settles, so macOS can register the app properly.
            try? await Task.sleep(for: .milliseconds(1_200))
            self?.runStartupAccessibilityCheckIfNeeded()
        }
    }

    private func runStartupAccessibilityCheckIfNeeded() {
        guard !startupAccessibilityCheckDidRun else { return }
        startupAccessibilityCheckDidRun = true

        guard !textInjector.hasAccessibilityPermission(promptIfNeeded: false) else { return }

        if textInjector.hasAccessibilityPermission(promptIfNeeded: true) {
            handleAccessibilityGranted()
            return
        }

        setError("Grant Accessibility permission in System Settings > Privacy & Security > Accessibility. VoiceBarDictate will pick it up automatically.")
        monitorAccessibilityPermissionUntilGranted()
    }

    private func monitorAccessibilityPermissionUntilGranted() {
        isWaitingForAccessibilityGrant = true
        accessibilityPermissionTask?.cancel()
        accessibilityPermissionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if textInjector.hasAccessibilityPermission(promptIfNeeded: false) {
                    handleAccessibilityGranted()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Creates the key-capture event tap now that it is allowed. Relaunches only if that still fails.
    private func handleAccessibilityGranted() {
        guard isWaitingForAccessibilityGrant || !escapeKeyMonitor.hasExclusiveCapture else { return }
        isWaitingForAccessibilityGrant = false
        accessibilityPermissionTask?.cancel()

        if escapeKeyMonitor.enableExclusiveCaptureIfPossible() {
            clearError()
            statusMessage = "Accessibility enabled."
            return
        }

        relaunchApp()
    }

    private func relaunchApp() {
        clearError()
        statusMessage = "Accessibility enabled. Restarting..."

        let process = Process()
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        }

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
        } catch {
            // Fall through and report the effective state.
        }
        let effectiveState = launchAtLoginService.isEnabled()
        launchAtLogin = effectiveState
        settingsStore.startAtLogin = effectiveState
    }
}
