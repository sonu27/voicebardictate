import AVFoundation
import Foundation

/// Microphone permission and capture via `AVAudioEngine`.
/// Audio can be encoded to a local m4a file (OpenAI) and/or streamed to a buffer handler (Apple On-Device).
@MainActor
final class AudioRecorderService {
    /// Called when the input device changes or disappears mid-recording (the engine stops itself).
    var onInputInterrupted: (() -> Void)?

    private var engine: AVAudioEngine?
    private var sink: RecordingSink?
    private var configurationObserver: NSObjectProtocol?

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Starts capturing from the default input device.
    /// - Parameters:
    ///   - writesFile: Encode audio to a temporary m4a file, returned by `stopRecording()`.
    ///   - buffersUntilHandlerAttached: Hold captured audio until `RecordingSink.attachBufferHandler(_:)` is called,
    ///     so nothing is lost while a live transcriber starts up.
    func startRecording(writesFile: Bool, buffersUntilHandlerAttached: Bool = false) throws -> RecordingSink {
        guard engine == nil else {
            throw RecorderError.alreadyRecording
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let fileURL = writesFile ? try Self.makeRecordingURL() : nil
        let sink = try RecordingSink(
            inputFormat: inputFormat,
            fileURL: fileURL,
            buffersUntilHandlerAttached: buffersUntilHandlerAttached
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: sink.makeTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            if let url = sink.finishFile() {
                try? FileManager.default.removeItem(at: url)
            }
            throw RecorderError.recordingFailed(error.localizedDescription)
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine, !engine.isRunning else { return }
                self.onInputInterrupted?()
            }
        }

        self.engine = engine
        self.sink = sink
        return sink
    }

    /// Stops capture and finalizes the file, if one was written. Safe to call when not recording.
    @discardableResult
    func stopRecording() -> URL? {
        guard let engine else {
            return nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        let fileURL = sink?.finishFile()
        self.engine = nil
        self.sink = nil
        return fileURL
    }

    func currentInputLevel() -> Double {
        sink?.currentLevel ?? 0
    }

    private static func makeRecordingURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceBarDictate",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
    }
}

/// Receives microphone buffers on the audio tap thread. Everything mutable is guarded by `lock`.
final class RecordingSink: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    /// Speech models work at 16 kHz mono, which also keeps uploads small.
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    static let minimumMeteringPower = -50.0

    let inputFormat: AVAudioFormat
    let fileURL: URL?

    private let lock = NSLock()
    private var file: AVAudioFile?
    private let fileConverter: PCMConverter?
    private var level = 0.0
    private var bufferHandler: BufferHandler?
    private var holdsBuffers: Bool
    private var heldBuffers: [AVAudioPCMBuffer] = []

    init(inputFormat: AVAudioFormat, fileURL: URL?, buffersUntilHandlerAttached: Bool) throws {
        self.inputFormat = inputFormat
        self.fileURL = fileURL
        self.holdsBuffers = buffersUntilHandlerAttached

        if let fileURL {
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: Self.fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let converter = PCMConverter(from: inputFormat, to: file.processingFormat) else {
                throw RecorderError.unsupportedInputFormat
            }
            self.file = file
            self.fileConverter = converter
        } else {
            self.fileConverter = nil
        }
    }

    /// Built outside any actor so the tap closure is not main-actor isolated (it runs on an audio thread).
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in
            process(buffer)
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let bufferLevel = Self.normalizedLevel(of: buffer)

        lock.lock()
        defer { lock.unlock() }

        level = bufferLevel
        if let file, let fileConverter, let converted = fileConverter.convert(buffer) {
            try? file.write(from: converted)
        }

        if let bufferHandler {
            bufferHandler(buffer)
        } else if holdsBuffers, let copy = buffer.deepCopy() {
            heldBuffers.append(copy)
        }
    }

    /// Delivers any held audio to `handler` in order, then streams new audio to it directly.
    func attachBufferHandler(_ handler: @escaping BufferHandler) {
        lock.lock()
        defer { lock.unlock() }

        for buffer in heldBuffers {
            handler(buffer)
        }
        heldBuffers.removeAll()
        holdsBuffers = false
        bufferHandler = handler
    }

    func detachBufferHandler() {
        lock.lock()
        defer { lock.unlock() }

        bufferHandler = nil
        holdsBuffers = false
        heldBuffers.removeAll()
    }

    /// Releases the file so AVAudioFile finalizes it, and returns its URL.
    func finishFile() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        file = nil
        return fileURL
    }

    var currentLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// RMS of the first channel mapped from -50...0 dBFS to 0...1.
    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(Double(sumOfSquares) / Double(frameCount))
        guard rms > 0 else { return 0 }

        let power = 20 * log10(rms)
        let clamped = max(minimumMeteringPower, min(0, power))
        return (clamped - minimumMeteringPower) / -minimumMeteringPower
    }
}

/// Streaming sample-rate / channel / sample-format conversion. Not thread-safe; callers serialize access.
final class PCMConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else {
            return buffer
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let input = ConverterInput(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if input.isConsumed {
                // `.noDataNow` keeps the converter's resampler state for the next buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.isConsumed = true
            inputStatus.pointee = .haveData
            return input.buffer
        }

        guard status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}

private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var isConsumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

extension AVAudioPCMBuffer {
    /// Tap buffers may be reused by the engine, so anything kept past the callback is copied.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(source, destination) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                continue
            }
            memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }
        return copy
    }
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case unsupportedInputFormat
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording has already started."
        case .noInputDevice:
            return "No microphone is available. Connect one or choose an input in System Settings > Sound."
        case .unsupportedInputFormat:
            return "The microphone's audio format is not supported."
        case .recordingFailed(let reason):
            return "The audio engine could not start: \(reason)"
        }
    }
}
