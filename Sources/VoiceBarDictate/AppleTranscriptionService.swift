import AVFoundation
import Speech

@available(macOS 26.0, *)
struct AppleTranscriptionService {
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

    func transcribe(fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)
        return try await withTaskCancellationHandler {
            async let transcript = Self.collectResults(from: transcriber)
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                return try await transcript
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var transcript = ""
        for try await result in transcriber.results where result.isFinal {
            transcript += String(result.text.characters)
        }
        return transcript
    }
}

enum AppleTranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple On-Device requires macOS 26 or later and a supported Mac. Choose another model in Settings."
        case .unsupportedLanguage(let identifier):
            return "Apple On-Device does not support \(identifier). Choose a supported language or another model in Settings."
        }
    }
}
