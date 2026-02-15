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
    @Published var livePreviewEnabled = false
    @Published var livePreviewText = ""
    @Published var isLivePreviewAvailableForCurrentModel = false

    @Published var apiKey: String {
        didSet {
            settingsStore.saveAPIKey(apiKey)
        }
    }

    @Published var model: String {
        didSet {
            settingsStore.model = model
            refreshLivePreviewAvailability(showDisableMessage: true)
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

    let livePreviewSupportedModels = [
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe"
    ]

    let hotkeyHint = "Control + Option + Space"

    var isUsingDotEnvAPIKey: Bool {
        settingsStore.isUsingDotEnvAPIKey
    }

    var debugLogFilePath: String {
        debugLogger.fileURL.path
    }

    private let settingsStore: SettingsStore
    private let debugLogger = DebugLogger.shared
    private let recorderService = AudioRecorderService()
    private let liveAudioCaptureService = LiveAudioCaptureService()
    private let transcriptionClient = OpenAITranscriptionClient()
    private let realtimeTranscriptionClient = RealtimeTranscriptionClient()
    private let textInjector = TextInjector()
    private let hotkeyManager = HotkeyManager()
    private let escapeKeyMonitor = EscapeKeyMonitor()
    private let recordingOverlay = RecordingOverlayController()
    private let liveTranscriptAccumulator = LiveTranscriptAccumulator()
    private let realtimeFinalizeTimeoutNanoseconds: UInt64 = 2_500_000_000

    private var recordingLevelTask: Task<Void, Never>?
    private var transcriptionTask: Task<String, Error>?
    private var accessibilityPermissionTask: Task<Void, Never>?
    private var accessibilityStartupTask: Task<Void, Never>?
    private var startupAccessibilityCheckDidRun = false
    private var shouldRelaunchAfterAccessibilityGrant = false
    private var isLiveSession = false
    private var isRealtimeConnectedForCurrentSession = false
    private var liveRealtimeFailureMessage: String?
    private var realtimeDeltaEventCount = 0
    private var realtimeCompletedEventCount = 0

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.apiKey = settingsStore.loadAPIKey()
        self.model = settingsStore.model
        self.apiBaseURL = settingsStore.apiBaseURL
        self.language = settingsStore.language
        self.prompt = settingsStore.prompt
        self.livePreviewEnabled = settingsStore.livePreviewEnabled

        refreshLivePreviewAvailability(showDisableMessage: false)
        setLivePreviewEnabled(livePreviewEnabled)
        debugLogger.info(
            "App initialized. model=\(model), livePreviewEnabled=\(livePreviewEnabled)",
            category: "app"
        )

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

        scheduleStartupAccessibilityCheck()
    }

    deinit {
        accessibilityPermissionTask?.cancel()
        accessibilityStartupTask?.cancel()
        recordingLevelTask?.cancel()
        transcriptionTask?.cancel()

        let realtimeClient = realtimeTranscriptionClient
        Task {
            await realtimeClient.disconnect()
        }
    }

    var menuBarSymbolName: String {
        if isRecording {
            return "waveform.circle.fill"
        }
        if isTranscribing {
            return "hourglass.circle.fill"
        }
        return "waveform"
    }

    func toggleFromMenu() {
        Task {
            await handleToggleRequest()
        }
    }

    func setLivePreviewEnabled(_ enabled: Bool) {
        let normalized = enabled && supportsLivePreview(model: model)
        livePreviewEnabled = normalized
        settingsStore.livePreviewEnabled = normalized
        debugLogger.info(
            "Live preview setting updated. requested=\(enabled), applied=\(normalized), model=\(model)",
            category: "settings"
        )
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

    func copyDebugLogPathToClipboard() {
        TextInjector.copyToClipboard(debugLogFilePath)
        statusMessage = "Debug log path copied."
    }

    func openDebugLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([debugLogger.fileURL])
        statusMessage = "Opened debug log location."
    }

    private func supportsLivePreview(model: String) -> Bool {
        livePreviewSupportedModels.contains(model)
    }

    private func refreshLivePreviewAvailability(showDisableMessage: Bool) {
        let isAvailable = supportsLivePreview(model: model)
        isLivePreviewAvailableForCurrentModel = isAvailable

        guard !isAvailable, livePreviewEnabled else {
            return
        }

        livePreviewEnabled = false
        settingsStore.livePreviewEnabled = false
        if showDisableMessage {
            statusMessage = "Live Preview disabled because \(model) does not support Realtime preview."
        }
    }

    private var shouldUseLivePreviewForNextSession: Bool {
        livePreviewEnabled && supportsLivePreview(model: model)
    }

    private var effectiveTranscriptionLanguage: String? {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if let localeCode = Locale.current.language.languageCode?.identifier.trimmingCharacters(in: .whitespacesAndNewlines),
           !localeCode.isEmpty {
            return localeCode
        }
        return "en"
    }

    private var effectiveTranscriptionPrompt: String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "Transcribe exactly what is spoken. Do not translate."
    }

    private func handleToggleRequest() async {
        if isTranscribing {
            debugLogger.warning("Ignoring toggle while transcribing.", category: "state")
            return
        }

        if isRecording {
            debugLogger.info("Stop requested.", category: "state")
            await stopAndTranscribe()
        } else {
            debugLogger.info("Start requested.", category: "state")
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
            debugLogger.error("Microphone permission denied.", category: "permissions")
            return
        }

        if shouldUseLivePreviewForNextSession {
            debugLogger.info("Starting live session path.", category: "session")
            await startLiveRecording()
        } else {
            debugLogger.info("Starting legacy session path.", category: "session")
            startLegacyRecording()
        }
    }

    private func startLegacyRecording() {
        do {
            _ = try recorderService.startRecording()
            isRecording = true
            isLiveSession = false
            resetLiveSessionState(clearPreviewText: true)
            escapeKeyMonitor.setCaptureActive(true)
            statusMessage = "Recording..."
            debugLogger.info("Legacy recording started.", category: "legacy")
            startRecordingLevelUpdates()
        } catch {
            escapeKeyMonitor.setCaptureActive(false)
            setError("Could not start recording: \(error.localizedDescription)")
            debugLogger.error("Legacy recording start failed: \(error.localizedDescription)", category: "legacy")
        }
    }

    private func startLiveRecording() async {
        do {
            resetLiveSessionState(clearPreviewText: true)
            isLiveSession = true

            let realtimeClient = realtimeTranscriptionClient
            try liveAudioCaptureService.startCapture { chunk in
                Task {
                    try? await realtimeClient.sendAudioChunk(chunk)
                }
            }

            isRecording = true
            escapeKeyMonitor.setCaptureActive(true)
            statusMessage = "Recording..."
            startRecordingLevelUpdates()

            do {
                try await realtimeTranscriptionClient.connect(
                    apiKey: apiKey,
                    baseURL: apiBaseURL,
                    model: model,
                    prompt: effectiveTranscriptionPrompt,
                    language: effectiveTranscriptionLanguage
                ) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleRealtimeEvent(event)
                    }
                }
                isRealtimeConnectedForCurrentSession = true
                statusMessage = "Listening..."
                debugLogger.info("Realtime connection established.", category: "live")
            } catch {
                liveRealtimeFailureMessage = error.localizedDescription
                statusMessage = "Live preview unavailable, finishing with standard transcription."
                debugLogger.error("Realtime connect failed: \(error.localizedDescription)", category: "live")
            }
        } catch {
            cleanupAfterFailedLiveStart()
            setError("Could not start recording: \(error.localizedDescription)")
            debugLogger.error("Live recording start failed: \(error.localizedDescription)", category: "live")
        }
    }

    private func stopAndTranscribe() async {
        if isLiveSession {
            await stopAndTranscribeLive()
        } else {
            await stopAndTranscribeLegacy()
        }
    }

    private func stopAndTranscribeLegacy() async {
        do {
            let audioFileURL = try recorderService.stopRecording()
            isRecording = false
            stopRecordingLevelUpdates()
            isTranscribing = true
            recordingOverlay.showTranscribing()
            statusMessage = "Transcribing..."
            debugLogger.info("Legacy stop complete. Starting transcription.", category: "legacy")

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
                    prompt: effectiveTranscriptionPrompt,
                    language: effectiveTranscriptionLanguage
                )
            }

            guard let transcriptionTask else {
                throw CancellationError()
            }
            let transcript = try await transcriptionTask.value
            try handleFinalTranscript(transcript)
        } catch is CancellationError {
            handleCanceledSession()
            debugLogger.warning("Legacy session canceled.", category: "legacy")
        } catch {
            isRecording = false
            stopRecordingLevelUpdates()
            escapeKeyMonitor.setCaptureActive(false)
            recordingOverlay.hide()
            setError("Could not stop and transcribe: \(error.localizedDescription)")
            debugLogger.error("Legacy stop/transcribe failed: \(error.localizedDescription)", category: "legacy")
        }
    }

    private func stopAndTranscribeLive() async {
        do {
            let liveAudioFileURL = try liveAudioCaptureService.stopCapture()
            isRecording = false
            stopRecordingLevelUpdates()
            isTranscribing = true
            recordingOverlay.showLiveFinalizing(text: livePreviewText)
            statusMessage = "Finalizing live transcript..."
            debugLogger.info(
                "Live stop complete. liveFile=\(liveAudioFileURL.lastPathComponent)",
                category: "live"
            )

            defer {
                transcriptionTask = nil
                isTranscribing = false
                escapeKeyMonitor.setCaptureActive(false)
                recordingOverlay.hide()
                try? FileManager.default.removeItem(at: liveAudioFileURL)
                scheduleRealtimeDisconnect()
                resetLiveSessionState(clearPreviewText: true)
            }

            var realtimeTranscript = ""
            var transcript = ""

            if isRealtimeConnectedForCurrentSession {
                do {
                    try await realtimeTranscriptionClient.finalize()
                    _ = await realtimeTranscriptionClient.waitForCompletion(timeoutNanoseconds: realtimeFinalizeTimeoutNanoseconds)
                    let snapshot = liveTranscriptAccumulator.snapshot()
                    let finalFromRealtime = snapshot.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalFromRealtime.isEmpty {
                        realtimeTranscript = finalFromRealtime
                        livePreviewText = finalFromRealtime
                        recordingOverlay.updateLiveText(finalFromRealtime)
                        debugLogger.info(
                            "Realtime final transcript ready for preview. length=\(finalFromRealtime.count)",
                            category: "live"
                        )
                    }
                } catch {
                    liveRealtimeFailureMessage = error.localizedDescription
                    debugLogger.error("Realtime finalize failed: \(error.localizedDescription)", category: "live")
                }
            }

            if liveRealtimeFailureMessage != nil || !isRealtimeConnectedForCurrentSession {
                statusMessage = "Live preview interrupted, finishing with standard transcription."
            } else {
                statusMessage = "Refining final transcript..."
            }
            debugLogger.info("Running final file transcription for live session.", category: "live")

            transcriptionTask = Task {
                try await transcriptionClient.transcribe(
                    fileURL: liveAudioFileURL,
                    apiKey: apiKey,
                    baseURL: apiBaseURL,
                    model: model,
                    prompt: effectiveTranscriptionPrompt,
                    language: effectiveTranscriptionLanguage
                )
            }

            guard let transcriptionTask else {
                throw CancellationError()
            }

            do {
                transcript = try await transcriptionTask.value
                debugLogger.info(
                    "Final file transcription completed. length=\(transcript.trimmingCharacters(in: .whitespacesAndNewlines).count)",
                    category: "live"
                )
            } catch {
                if !realtimeTranscript.isEmpty {
                    transcript = realtimeTranscript
                    debugLogger.warning(
                        "Final file transcription failed; using realtime final transcript. length=\(realtimeTranscript.count)",
                        category: "live"
                    )
                } else {
                    throw error
                }
            }

            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !realtimeTranscript.isEmpty {
                transcript = realtimeTranscript
                debugLogger.warning(
                    "Final file transcription was empty; using realtime final transcript. length=\(realtimeTranscript.count)",
                    category: "live"
                )
            }

            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let previewFallback = liveTranscriptAccumulator.snapshot().previewText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !previewFallback.isEmpty {
                    transcript = previewFallback
                    debugLogger.warning(
                        "Using accumulated preview text as last-resort final transcript. length=\(previewFallback.count)",
                        category: "live"
                    )
                }
            }

            try handleFinalTranscript(transcript)
        } catch is CancellationError {
            handleCanceledSession()
            debugLogger.warning("Live session canceled.", category: "live")
        } catch {
            isRecording = false
            stopRecordingLevelUpdates()
            escapeKeyMonitor.setCaptureActive(false)
            recordingOverlay.hide()
            scheduleRealtimeDisconnect()
            resetLiveSessionState(clearPreviewText: true)
            setError("Could not stop and transcribe: \(error.localizedDescription)")
            debugLogger.error("Live stop/transcribe failed: \(error.localizedDescription)", category: "live")
        }
    }

    private func handleFinalTranscript(_ transcript: String) throws {
        let normalizedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            statusMessage = "No speech detected."
            debugLogger.warning("Final transcript empty after normalization.", category: "transcript")
            return
        }

        lastTranscript = normalizedText
        if isLiveSession {
            livePreviewText = normalizedText
            recordingOverlay.updateLiveText(normalizedText)
        }
        debugLogger.info(
            "Final transcript ready. length=\(normalizedText.count), liveSession=\(isLiveSession)",
            category: "transcript"
        )

        do {
            try textInjector.inject(text: normalizedText)
            clearError()
            statusMessage = "Transcribed and pasted."
            debugLogger.info("Text injection succeeded.", category: "inject")
        } catch {
            setError("Transcribed but failed to paste automatically: \(error.localizedDescription)")
            debugLogger.error("Text injection failed: \(error.localizedDescription)", category: "inject")
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeTranscriptionClient.Event) {
        guard isLiveSession else { return }

        switch event {
        case .committed(let itemID, let previousItemID):
            let snapshot = liveTranscriptAccumulator.handleCommitted(
                itemID: itemID,
                previousItemID: previousItemID
            )
            applyLiveSnapshot(snapshot)
            debugLogger.info(
                "Realtime committed. itemID=\(itemID), previousItemID=\(previousItemID ?? "nil")",
                category: "realtime"
            )

        case .delta(let itemID, let text):
            realtimeDeltaEventCount += 1
            let snapshot = liveTranscriptAccumulator.handleDelta(itemID: itemID, delta: text)
            applyLiveSnapshot(snapshot)
            if realtimeDeltaEventCount % 25 == 0 {
                debugLogger.info(
                    "Realtime delta progress. count=\(realtimeDeltaEventCount), lastItemID=\(itemID), deltaLength=\(text.count), previewLength=\(snapshot.previewText.count)",
                    category: "realtime"
                )
            }

        case .completed(let itemID, let text):
            realtimeCompletedEventCount += 1
            let snapshot = liveTranscriptAccumulator.handleCompleted(itemID: itemID, text: text)
            applyLiveSnapshot(snapshot)
            debugLogger.info(
                "Realtime completed. count=\(realtimeCompletedEventCount), itemID=\(itemID), textLength=\(text.count), finalLength=\(snapshot.finalText.count)",
                category: "realtime"
            )

        case .failed(let message):
            isRealtimeConnectedForCurrentSession = false
            liveRealtimeFailureMessage = message
            if isRecording {
                statusMessage = "Live preview interrupted, finishing with standard transcription."
            }
            debugLogger.error("Realtime failed: \(message)", category: "realtime")

        case .disconnected(let message):
            isRealtimeConnectedForCurrentSession = false
            liveRealtimeFailureMessage = message
            if isRecording {
                statusMessage = "Live preview interrupted, finishing with standard transcription."
            }
            debugLogger.warning("Realtime disconnected: \(message)", category: "realtime")
        }
    }

    private func applyLiveSnapshot(_ snapshot: LiveTranscriptSnapshot) {
        let preview = snapshot.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        livePreviewText = preview

        if isRecording {
            recordingOverlay.updateLiveRecording(level: recordingLevel, text: preview)
        } else if isTranscribing {
            recordingOverlay.updateLiveText(preview)
        }
    }

    private func startRecordingLevelUpdates() {
        stopRecordingLevelUpdates()
        recordingLevel = 0

        if isLiveSession {
            recordingOverlay.showLiveRecording(level: 0, text: livePreviewText)
        } else {
            recordingOverlay.showRecording(level: 0)
        }

        recordingLevelTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let sample = isLiveSession ? liveAudioCaptureService.currentInputLevel() : recorderService.currentInputLevel()
                recordingLevel = smoothedLevel(previous: recordingLevel, next: sample)

                if isLiveSession {
                    recordingOverlay.updateLiveRecording(level: recordingLevel, text: livePreviewText)
                } else {
                    recordingOverlay.updateRecordingLevel(recordingLevel)
                }

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
        if isLiveSession {
            liveAudioCaptureService.discardCapture()
            scheduleRealtimeDisconnect()
            resetLiveSessionState(clearPreviewText: true)
        } else if let audioURL = try? recorderService.stopRecording() {
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
        scheduleRealtimeDisconnect()
        statusMessage = "Canceling..."
    }

    private func cleanupAfterFailedLiveStart() {
        liveAudioCaptureService.discardCapture()
        scheduleRealtimeDisconnect()
        resetLiveSessionState(clearPreviewText: true)
        isRecording = false
        stopRecordingLevelUpdates()
        debugLogger.warning("Cleaned up failed live session start.", category: "live")
    }

    private func resetLiveSessionState(clearPreviewText: Bool) {
        isLiveSession = false
        isRealtimeConnectedForCurrentSession = false
        liveRealtimeFailureMessage = nil
        realtimeDeltaEventCount = 0
        realtimeCompletedEventCount = 0
        liveTranscriptAccumulator.reset()
        if clearPreviewText {
            livePreviewText = ""
        }
    }

    private func scheduleRealtimeDisconnect() {
        let realtimeClient = realtimeTranscriptionClient
        Task {
            await realtimeClient.disconnect()
        }
    }

    private func handleCanceledSession() {
        isRecording = false
        stopRecordingLevelUpdates()
        escapeKeyMonitor.setCaptureActive(false)
        recordingOverlay.hide()
        scheduleRealtimeDisconnect()
        resetLiveSessionState(clearPreviewText: true)
        clearError()
        statusMessage = "Dictation canceled."
        debugLogger.warning("Session canceled by user.", category: "session")
    }

    private func clearError() {
        errorMessage = nil
    }

    private func setError(_ message: String) {
        errorMessage = message
        statusMessage = message
        debugLogger.error("User-facing error set: \(message)", category: "error")
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
}
