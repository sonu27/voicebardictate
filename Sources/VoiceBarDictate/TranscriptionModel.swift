enum TranscriptionModel: String, CaseIterable {
    case gptTranscribe = "gpt-transcribe"
    case appleOnDevice = "apple-on-device"

    var displayName: String {
        switch self {
        case .gptTranscribe: return "GPT-Transcribe"
        case .appleOnDevice: return "Apple On-Device"
        }
    }
}
