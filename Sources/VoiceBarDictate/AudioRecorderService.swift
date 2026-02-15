import AVFoundation
import Foundation

@MainActor
final class AudioRecorderService: NSObject {
    private var recorder: AVAudioRecorder?

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startRecording() throws -> URL {
        if recorder != nil {
            throw RecorderError.alreadyRecording
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceBarDictate",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw RecorderError.recordingFailed
        }

        self.recorder = recorder
        return fileURL
    }

    func stopRecording() throws -> URL {
        guard let recorder else {
            throw RecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        return recorder.url
    }
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording has already started."
        case .notRecording:
            return "Recording has not started."
        case .recordingFailed:
            return "AVAudioRecorder could not start recording."
        }
    }
}
