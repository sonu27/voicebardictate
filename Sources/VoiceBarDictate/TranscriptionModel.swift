/// The transcription engine. Raw values are persisted, so keep them stable.
/// The OpenAI model ID sent to the API is a separate setting (`SettingsStore.openAIModelID`).
enum TranscriptionModel: String, CaseIterable {
    case gptTranscribe = "gpt-transcribe"
    case appleOnDevice = "apple-on-device"

    static let defaultOpenAIModelID = "gpt-transcribe"

    /// Values written by earlier versions, when the stored value was the OpenAI model ID itself.
    static let legacyOpenAIModelIDs: Set<String> = [
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
        "whisper-1"
    ]

    var displayName: String {
        switch self {
        case .gptTranscribe: return "OpenAI"
        case .appleOnDevice: return "Apple On-Device"
        }
    }
}
