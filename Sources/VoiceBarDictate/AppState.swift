import AppKit
import ApplicationServices
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

/// The one notice the popover shows between the engine switch and the last transcript, highest priority first.
enum PopoverNotice: Equatable {
    case downloading(progress: Double, languageName: String)
    case accessibilityMissing
    case microphoneDenied
    case apiKeyMissing
    case onDeviceUnavailable
    case error(String)
    /// A one-off notice, e.g. that a retired OpenAI model was replaced.
    case info(String)
}

/// What the menu bar icon shows.
enum MenuBarIconState: Equatable {
    case idle
    case recording
    case transcribing
    case downloading(progress: Double)
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
    private(set) var lastTranscriptDate: Date?
    private(set) var launchAtLogin = false
    /// 0...1 while the Apple On-Device language model downloads, otherwise nil.
    private(set) var appleModelDownloadProgress: Double?
    /// The display name of the language being downloaded, e.g. "English (United Kingdom)".
    private(set) var appleModelDownloadLanguageName = ""
    /// When the current recording began; drives the timers in the popover and the overlay.
    private(set) var recordingStartedAt: Date?
    /// Partial text from a live (on-device) transcriber while recording.
    private(set) var liveText = ""
    private(set) var hasAccessibilityPermission = AXIsProcessTrusted()
    private(set) var isMicrophoneDenied = false
    private(set) var infoMessage: String?

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

    var menuBarIconState: MenuBarIconState {
        switch phase {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .idle, .starting:
            if let progress = appleModelDownloadProgress { return .downloading(progress: progress) }
            return .idle
        }
    }

    var isOnDeviceSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// True while the on-device model is still downloading, so dictation with it cannot start yet.
    var isWaitingForAppleModel: Bool {
        model == .appleOnDevice && appleModelDownloadProgress != nil
    }

    var notice: PopoverNotice? {
        if model == .appleOnDevice, let progress = appleModelDownloadProgress {
            return .downloading(progress: progress, languageName: appleModelDownloadLanguageName)
        }
        if !hasAccessibilityPermission { return .accessibilityMissing }
        if isMicrophoneDenied { return .microphoneDenied }
        if model == .gptTranscribe, apiKey.isEmpty { return .apiKeyMissing }
        if model == .appleOnDevice, !isOnDeviceSupported { return .onDeviceUnavailable }
        if let errorMessage { return .error(errorMessage) }
        if let infoMessage { return .info(infoMessage) }
        return nil
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
    @ObservationIgnored private var silenceDetector = SilenceDetector()
    @ObservationIgnored private var inputDeviceName = ""
    /// The last app other than this one to become active, so popover actions can paste back into it.
    @ObservationIgnored private var previousApplication: NSRunningApplication?
    @ObservationIgnored private var appActivationObserver: NSObjectProtocol?

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
        // The overlay's Insert and Cancel buttons do what Return and Escape do.
        recordingOverlay.onInsert = { [weak self] in self?.handleReturnPressed() }
        recordingOverlay.onCancel = { [weak self] in self?.handleEscapePressed() }
        recorderService.onInputInterrupted = { [weak self] in
            self?.handleInputInterrupted()
        }

        registerHotkey()
        trackPreviousApplication()
        refreshPermissions()

        if let legacyModelID = settingsStore.migratedLegacyModelID {
            statusMessage = "\(legacyModelID) was retired. Now using \(openAIModelID)."
            infoMessage = statusMessage
        }

        syncLaunchAtLoginPreferenceAtStartup()
        scheduleStartupAccessibilityCheck()

        if model == .appleOnDevice {
            prepareAppleModelIfNeeded()
        }
    }

    // MARK: - Menu and Settings actions

    /// The popover's primary button. The popover closes itself first; this hands focus back to the app the
    /// user was typing in, so the transcript is pasted there and not into this app's panel.
    func toggleFromMenu() {
        Task {
            await focusPreviousApplicationIfNeeded()
            handleToggleRequest()
        }
    }

    func setEngine(_ newModel: TranscriptionModel) {
        guard canChangeModel, newModel != model else { return }
        var draft = currentSettings
        draft.model = newModel
        saveSettings(draft)
    }

    /// Re-reads permission states that can change in System Settings while the app runs.
    func refreshPermissions() {
        hasAccessibilityPermission = textInjector.hasAccessibilityPermission(promptIfNeeded: false)
        isMicrophoneDenied = recorderService.isPermissionDenied
    }

    func dismissError() {
        clearError()
    }

    func dismissInfo() {
        infoMessage = nil
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
        monitorAccessibilityPermissionUntilGranted()
    }

    func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Pastes the last transcript again into the app the user was in before opening the popover.
    func pasteLastTranscript() {
        guard phase == .idle, !lastTranscript.isEmpty else { return }
        let text = lastTranscript
        Task { await insert(text) }
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
            hasAccessibilityPermission = true
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

    // MARK: - Focus

    private func trackPreviousApplication() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            previousApplication = frontmost
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ownPID
            else {
                return
            }
            MainActor.assumeIsolated { self?.previousApplication = app }
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("settings") == true || window.title == "VoiceBar Settings"
    }

    /// When this app is frontmost (the popover was just used), reactivates the previous app and waits for it,
    /// so a synthetic Cmd+V reaches the user's text field. Does nothing for hotkey-driven dictation.
    private func focusPreviousApplicationIfNeeded() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Leave focus alone when the user is typing in this app's own Settings window.
        if let keyWindow = NSApp.keyWindow, Self.isSettingsWindow(keyWindow) {
            return
        }
        MenuBarPanel.close()
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID || NSApp.isActive,
            let target = previousApplication,
            !target.isTerminated
        else {
            return
        }

        target.activate()
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Give the app a moment to restore its key window and text focus.
        try? await Task.sleep(for: .milliseconds(80))
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
        setError(message)
        recordingOverlay.showError(title: "Couldn't start dictation", detail: message)
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
        isMicrophoneDenied = recorderService.isPermissionDenied
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

        let startedAt = Date()
        recordingStartedAt = startedAt
        liveText = ""
        phase = .recording
        statusMessage = "Recording..."
        // Accessibility may have been granted since launch; try for system-wide Return/Escape again.
        if !escapeKeyMonitor.hasExclusiveCapture {
            escapeKeyMonitor.enableExclusiveCaptureIfPossible()
        }
        recordingOverlay.showListening(
            startedAt: startedAt,
            hints: ListeningHints(
                releaseToInsert: hotkeyMode == .hold && isHoldingHotkey,
                capturesKeys: escapeKeyMonitor.hasExclusiveCapture
            )
        )
        startRecordingLevelUpdates(startedAt: startedAt)
    }

    private func updateLiveText(_ text: String) {
        guard phase == .recording else { return }
        liveText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingOverlay.updateLiveText(liveText)
    }

    private func endRecordingState() {
        stopRecordingLevelUpdates()
        recordingStartedAt = nil
        liveText = ""
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
            startAppleModelDownload(request, locale: locale, announceCompletion: true)
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
                    self?.updateLiveText(text)
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
        recordingOverlay.showError(title: "Couldn't start on-device dictation", detail: error.localizedDescription)
    }

    private func stopAndTranscribe() async {
        guard phase == .recording, let recording = activeRecording else { return }
        activeRecording = nil
        endRecordingState()
        phase = .transcribing
        recordingOverlay.showTranscribing(engineName: model == .appleOnDevice ? "On-device" : "OpenAI")
        statusMessage = "Transcribing..."

        let audioFileURL = recorderService.stopRecording()
        defer {
            transcriptionTask = nil
            phase = .idle
            if let audioFileURL {
                try? FileManager.default.removeItem(at: audioFileURL)
            }
        }

        let task: Task<String, Error>
        switch recording {
        case .openAI:
            guard let audioFileURL else {
                failTranscription("No audio was recorded.")
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

        let normalizedText: String
        do {
            let transcript = try await task.value
            guard !task.isCancelled else { throw CancellationError() }
            normalizedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if error is CancellationError || task.isCancelled {
                clearError()
                statusMessage = "Dictation canceled."
                recordingOverlay.hide()
            } else {
                failTranscription(error.localizedDescription)
            }
            return
        }

        guard !normalizedText.isEmpty else {
            statusMessage = "No speech detected."
            recordingOverlay.showMessage("No speech detected.")
            return
        }

        lastTranscript = normalizedText
        lastTranscriptDate = Date()
        await insert(normalizedText)
    }

    private func failTranscription(_ detail: String) {
        setError("Could not transcribe: \(detail)")
        recordingOverlay.showError(title: "Couldn't transcribe", detail: detail)
    }

    /// Pastes `text` into the frontmost app and reports the result in the overlay.
    /// If pasting is impossible, the transcript is left on the clipboard instead.
    private func insert(_ text: String) async {
        await focusPreviousApplicationIfNeeded()
        // Clear the overlay as the text lands, rather than after the clipboard restore delay inside `inject`.
        recordingOverlay.hide()
        do {
            try await textInjector.inject(text: text)
            clearError()
            statusMessage = "Transcribed and pasted."
        } catch {
            // `inject` throws before it touches the clipboard, so put the transcript there for a manual paste.
            TextInjector.copyToClipboard(text)
            refreshPermissions()
            let reason = (error as? TextInjectionError) == .accessibilityPermissionMissing
                ? "Accessibility access is off."
                : "macOS didn't accept the paste."
            setError("Transcribed but couldn't paste. \(reason) The transcript is on your clipboard.")
            recordingOverlay.showError(
                title: "Couldn't paste the transcript",
                detail: "\(reason) The transcript is on your clipboard. Press ⌘V to paste it."
            )
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

        endRecordingState()
        phase = .idle
        recordingOverlay.hide()
        clearError()
        statusMessage = "Dictation canceled."
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        statusMessage = "Canceling..."
    }

    private func startRecordingLevelUpdates(startedAt: Date) {
        stopRecordingLevelUpdates()
        silenceDetector = SilenceDetector(startedAt: startedAt)
        inputDeviceName = recorderService.defaultInputDeviceName ?? "your microphone"

        recordingLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = recorderService.currentInputLevel()
                recordingLevel = Self.smoothedLevel(previous: recordingLevel, next: sample)
                let isSilent = silenceDetector.update(level: sample)
                recordingOverlay.updateLevel(
                    recordingLevel,
                    silentDeviceName: isSilent ? inputDeviceName : nil
                )
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
            startAppleModelDownload(request, locale: locale, announceCompletion: false)
            statusMessage = "Downloading the Apple On-Device language model..."
        }
    }

    @available(macOS 26.0, *)
    private func startAppleModelDownload(_ request: AssetInstallationRequest, locale: Locale, announceCompletion: Bool) {
        appleModelDownloadLanguageName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
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
                    recordingOverlay.showMessage("On-device dictation is ready. Press \(hotkey.displayString) to dictate.")
                }
            } catch {
                setError("Could not download the Apple On-Device language model: \(error.localizedDescription)")
            }
        }
    }

    private func reportAppleModelDownloadInProgress() {
        let percent = Int(((appleModelDownloadProgress ?? 0) * 100).rounded())
        let message = "The on-device model is downloading (\(percent)%). Dictation is available when it finishes."
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

        // Show the system prompt once. After that the popover's notice card says what's missing and links to
        // System Settings, instead of a prompt at every launch.
        if !settingsStore.hasShownAccessibilityPrompt {
            settingsStore.hasShownAccessibilityPrompt = true
            if textInjector.hasAccessibilityPermission(promptIfNeeded: true) {
                handleAccessibilityGranted()
                return
            }
        }

        hasAccessibilityPermission = false
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
        hasAccessibilityPermission = true
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

#if DEBUG
extension AppState {
    /// The popover scenarios drawn in `docs/design/voicebar-dark-mockups.html`.
    enum DebugScenario: String, CaseIterable {
        case idleOnDevice = "popover-idle"
        case recording = "popover-recording"
        case downloading = "popover-downloading"
        case holdOpenAIPermissionMissing = "popover-hold-openai"
    }

    /// Puts in-memory state into a scenario for snapshots. Nothing is persisted, and `restore` undoes it.
    func debugApply(_ scenario: DebugScenario) -> () -> Void {
        let saved = (phase, model, hotkeyMode, lastTranscript, lastTranscriptDate, liveText, recordingStartedAt,
                     appleModelDownloadProgress, appleModelDownloadLanguageName, hasAccessibilityPermission, errorMessage)
        errorMessage = nil
        hasAccessibilityPermission = true
        switch scenario {
        case .idleOnDevice:
            model = .appleOnDevice
            lastTranscript = "Could you check the PostgreSQL connection before the meeting?"
            lastTranscriptDate = Date().addingTimeInterval(-120)
        case .recording:
            model = .appleOnDevice
            recordingStartedAt = Date().addingTimeInterval(-7)
            liveText = "Could you check the PostgreSQL connection before the meet"
            phase = .recording
        case .downloading:
            model = .appleOnDevice
            appleModelDownloadProgress = 0.62
            appleModelDownloadLanguageName = "English (United Kingdom)"
            lastTranscript = "Send the release notes to the design channel."
            lastTranscriptDate = Date().addingTimeInterval(-86_400)
        case .holdOpenAIPermissionMissing:
            model = .gptTranscribe
            hotkeyMode = .hold
            hasAccessibilityPermission = false
            lastTranscript = ""
            lastTranscriptDate = nil
        }
        return { [self] in
            (phase, model, hotkeyMode, lastTranscript, lastTranscriptDate, liveText, recordingStartedAt,
             appleModelDownloadProgress, appleModelDownloadLanguageName, hasAccessibilityPermission, errorMessage) = saved
        }
    }
}
#endif
