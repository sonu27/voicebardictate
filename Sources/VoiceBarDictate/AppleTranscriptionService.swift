import AVFoundation
import Speech

/// A transcription that receives audio while the user is still speaking.
@MainActor
protocol LiveTranscriptionSession: AnyObject {
    /// Ends the audio input and returns the final transcript.
    func finish() async throws -> String
    /// Stops immediately and discards results.
    func cancel() async
}

@available(macOS 26.0, *)
enum AppleSpeechModel {
    static func locale(for language: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw AppleTranscriptionError.unavailable
        }

        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let requested = Locale(identifier: language.isEmpty ? preferred : language)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return match
        }
        throw AppleTranscriptionError.unsupportedLanguage(requested.identifier)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    /// Returns a download request when the language model for `locale` is not installed yet, otherwise nil.
    static func installationRequest(for locale: Locale) async throws -> AssetInstallationRequest? {
        try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale: locale)])
    }
}

/// Streams microphone audio into `SpeechAnalyzer`, reporting partial text as it is recognized.
@available(macOS 26.0, *)
@MainActor
final class AppleLiveTranscription: LiveTranscriptionSession {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<String, Error>?

    init(locale: Locale) {
        transcriber = AppleSpeechModel.makeTranscriber(locale: locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    /// Starts the analyzer and returns a handler that converts and forwards captured audio to it.
    /// `onUpdate` receives the full text so far (final plus volatile results).
    func start(
        inputFormat: AVAudioFormat,
        onUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> RecordingSink.BufferHandler {
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: inputFormat
            ),
            let converter = PCMConverter(from: inputFormat, to: analyzerFormat)
        else {
            throw AppleTranscriptionError.unsupportedAudioFormat
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let transcriber = self.transcriber
        resultsTask = Task { @MainActor in
            var finalized = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    onUpdate(finalized)
                } else {
                    onUpdate(finalized + text)
                }
            }
            return finalized
        }

        try await analyzer.start(inputSequence: inputStream)
        return Self.makeBufferHandler(converter: converter, continuation: inputContinuation)
    }

    func finish() async throws -> String {
        inputContinuation.finish()
        let analyzer = self.analyzer
        return try await withTaskCancellationHandler {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultsTask?.value ?? ""
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    func cancel() async {
        inputContinuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    /// Nonisolated so the returned closure can run on the audio tap thread.
    nonisolated private static func makeBufferHandler(
        converter: PCMConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> RecordingSink.BufferHandler {
        { buffer in
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }
}

enum AppleTranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple On-Device requires macOS 26 or later and a supported Mac. Choose another model in Settings."
        case .unsupportedLanguage(let identifier):
            return "Apple On-Device does not support \(identifier). Choose a supported language or another model in Settings."
        case .unsupportedAudioFormat:
            return "Apple On-Device cannot use this microphone's audio format."
        }
    }
}
