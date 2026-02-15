import AVFoundation
import Foundation

final class LiveAudioCaptureService {
    private let targetSampleRate: Double = 24_000
    private let targetChannels: AVAudioChannelCount = 1
    private let minimumMeteringPower: Float = -50
    private let stateQueue = DispatchQueue(label: "VoiceBarDictate.LiveAudioCaptureService.state")
    private let debugLogger = DebugLogger.shared

    private var engine: AVAudioEngine?
    private var onAudioChunk: ((Data) -> Void)?
    private var fallbackPCMData = Data()
    private var fallbackSampleRate: Double = 24_000
    private var currentLevel: Double = 0
    private var chunkCount = 0
    private var totalChunkBytes = 0
    private var tapBufferCount = 0
    private var streamResampledChunkCount = 0

    func startCapture(onAudioChunk: @escaping (Data) -> Void) throws {
        guard engine == nil else {
            throw LiveAudioCaptureError.alreadyRecording
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        stateQueue.sync {
            self.fallbackPCMData.removeAll(keepingCapacity: true)
            self.fallbackSampleRate = inputFormat.sampleRate
            self.currentLevel = 0
            self.chunkCount = 0
            self.totalChunkBytes = 0
            self.tapBufferCount = 0
            self.streamResampledChunkCount = 0
        }

        self.onAudioChunk = onAudioChunk
        self.engine = engine

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            debugLogger.info(
                "Live audio capture started. inputSampleRate=\(inputFormat.sampleRate), inputChannels=\(inputFormat.channelCount), outputSampleRate=\(targetSampleRate)",
                category: "audio"
            )
        } catch {
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            self.onAudioChunk = nil
            debugLogger.error("Live audio capture failed to start: \(error.localizedDescription)", category: "audio")
            throw LiveAudioCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    func stopCapture() throws -> URL {
        guard let engine else {
            throw LiveAudioCaptureError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        self.engine = nil
        self.onAudioChunk = nil

        let captureResult = stateQueue.sync {
            let data = fallbackPCMData
            let sampleRate = fallbackSampleRate
            let stats = (
                chunks: chunkCount,
                streamBytes: totalChunkBytes,
                tapBuffers: tapBufferCount,
                resampledStreamChunks: streamResampledChunkCount
            )
            fallbackPCMData.removeAll(keepingCapacity: true)
            currentLevel = 0
            chunkCount = 0
            totalChunkBytes = 0
            tapBufferCount = 0
            streamResampledChunkCount = 0
            debugLogger.info(
                "Live audio capture stopped. chunks=\(stats.chunks), streamBytes=\(stats.streamBytes), fallbackPcmBytes=\(data.count), tapBuffers=\(stats.tapBuffers), resampledStreamChunks=\(stats.resampledStreamChunks)",
                category: "audio"
            )
            return (data, sampleRate)
        }

        return try writeTemporaryWAVFile(pcmData: captureResult.0, sampleRate: captureResult.1)
    }

    func discardCapture() {
        guard let engine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        self.engine = nil
        self.onAudioChunk = nil

        stateQueue.sync {
            fallbackPCMData.removeAll(keepingCapacity: true)
            fallbackSampleRate = targetSampleRate
            currentLevel = 0
            chunkCount = 0
            totalChunkBytes = 0
            tapBufferCount = 0
            streamResampledChunkCount = 0
        }
        debugLogger.warning("Live audio capture discarded.", category: "audio")
    }

    func currentInputLevel() -> Double {
        stateQueue.sync {
            currentLevel
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = normalizedLevel(from: buffer)
        let nativeChunk = pcm16MonoChunk(from: buffer)
        let streamChunk = streamChunk24k(from: nativeChunk, inputSampleRate: buffer.format.sampleRate)
        let didResample = Int(buffer.format.sampleRate.rounded()) != Int(targetSampleRate)

        stateQueue.sync {
            tapBufferCount += 1
            currentLevel = level

            if let nativeChunk, !nativeChunk.isEmpty {
                fallbackPCMData.append(nativeChunk)
            }

            if let streamChunk, !streamChunk.isEmpty {
                chunkCount += 1
                totalChunkBytes += streamChunk.count
                if didResample {
                    streamResampledChunkCount += 1
                }
            }

            if chunkCount % 200 == 0 {
                debugLogger.info(
                    "Live audio chunk progress. chunks=\(chunkCount), streamBytes=\(totalChunkBytes), fallbackPcmBytes=\(fallbackPCMData.count)",
                    category: "audio"
                )
            }
        }

        if let streamChunk, !streamChunk.isEmpty {
            onAudioChunk?(streamChunk)
        }
    }

    private func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else {
            return 0
        }

        if let channelData = buffer.floatChannelData {
            let sampleCount = Int(buffer.frameLength)
            let channelSamples = channelData[0]
            var sumOfSquares: Float = 0
            for index in 0..<sampleCount {
                let sample = channelSamples[index]
                sumOfSquares += sample * sample
            }

            let rms = sqrt(sumOfSquares / Float(sampleCount))
            let db = max(minimumMeteringPower, min(0, 20 * log10(max(rms, 0.000_000_1))))
            let normalized = (db - minimumMeteringPower) / -minimumMeteringPower
            return Double(normalized)
        }

        guard let channelData = buffer.int16ChannelData else {
            return 0
        }

        let sampleCount = Int(buffer.frameLength)
        let channelSamples = channelData[0]
        var sumOfSquares: Float = 0
        for index in 0..<sampleCount {
            let sample = Float(channelSamples[index]) / Float(Int16.max)
            sumOfSquares += sample * sample
        }

        let rms = sqrt(sumOfSquares / Float(sampleCount))
        let db = max(minimumMeteringPower, min(0, 20 * log10(max(rms, 0.000_000_1))))
        let normalized = (db - minimumMeteringPower) / -minimumMeteringPower
        return Double(normalized)
    }

    private func writeTemporaryWAVFile(pcmData: Data, sampleRate: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceBarDictate",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let wavData = buildWAVData(
            pcmData: pcmData,
            sampleRate: UInt32(max(1, Int(sampleRate.rounded()))),
            channels: UInt16(targetChannels),
            bitsPerSample: 16
        )

        do {
            try wavData.write(to: fileURL, options: .atomic)
            debugLogger.info(
                "WAV fallback file written. path=\(fileURL.lastPathComponent), bytes=\(wavData.count)",
                category: "audio"
            )
            return fileURL
        } catch {
            debugLogger.error("WAV fallback write failed: \(error.localizedDescription)", category: "audio")
            throw LiveAudioCaptureError.fileWriteFailed(error.localizedDescription)
        }
    }

    private func buildWAVData(
        pcmData: Data,
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataChunkSize = UInt32(pcmData.count)
        let riffChunkSize = 36 + dataChunkSize

        var data = Data(capacity: Int(riffChunkSize) + 8)
        data.appendASCII("RIFF")
        data.appendLittleEndian(riffChunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataChunkSize)
        data.append(pcmData)
        return data
    }

    private func pcm16MonoChunk(from buffer: AVAudioPCMBuffer) -> Data? {
        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else {
            return nil
        }

        let channelCount = max(Int(buffer.format.channelCount), 1)
        var chunk = Data(count: sampleCount * MemoryLayout<Int16>.size)

        if let floatChannels = buffer.floatChannelData {
            chunk.withUnsafeMutableBytes { rawBuffer in
                guard let output = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
                for index in 0..<sampleCount {
                    var sample: Float = 0
                    for channel in 0..<channelCount {
                        sample += floatChannels[channel][index]
                    }
                    sample /= Float(channelCount)
                    let clamped = max(-1, min(1, sample))
                    output[index] = Int16(clamped * Float(Int16.max))
                }
            }
            return chunk
        }

        if let int16Channels = buffer.int16ChannelData {
            if channelCount == 1 {
                return Data(bytes: int16Channels[0], count: sampleCount * MemoryLayout<Int16>.size)
            }

            chunk.withUnsafeMutableBytes { rawBuffer in
                guard let output = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
                for index in 0..<sampleCount {
                    var sum = 0
                    for channel in 0..<channelCount {
                        sum += Int(int16Channels[channel][index])
                    }
                    output[index] = Int16(sum / channelCount)
                }
            }
            return chunk
        }

        return nil
    }

    private func streamChunk24k(from nativeChunk: Data?, inputSampleRate: Double) -> Data? {
        guard let nativeChunk, !nativeChunk.isEmpty else {
            return nil
        }

        guard abs(inputSampleRate - targetSampleRate) > 0.5 else {
            return nativeChunk
        }

        return resamplePCM16Mono(
            chunk: nativeChunk,
            inputSampleRate: inputSampleRate,
            outputSampleRate: targetSampleRate
        )
    }

    private func resamplePCM16Mono(
        chunk: Data,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> Data {
        let inputSampleCount = chunk.count / MemoryLayout<Int16>.size
        guard inputSampleCount > 0, inputSampleRate > 0, outputSampleRate > 0 else {
            return chunk
        }

        let outputSampleCount = max(1, Int((Double(inputSampleCount) * outputSampleRate / inputSampleRate).rounded()))
        var output = Data(count: outputSampleCount * MemoryLayout<Int16>.size)

        chunk.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                guard
                    let input = inputRaw.bindMemory(to: Int16.self).baseAddress,
                    let result = outputRaw.bindMemory(to: Int16.self).baseAddress
                else {
                    return
                }

                for outputIndex in 0..<outputSampleCount {
                    let sourcePosition = (Double(outputIndex) * inputSampleRate) / outputSampleRate
                    let sourceIndex = min(Int(sourcePosition.rounded(.down)), inputSampleCount - 1)
                    result[outputIndex] = input[sourceIndex]
                }
            }
        }

        return output
    }
}

enum LiveAudioCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case conversionSetupFailed
    case engineStartFailed(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Live audio capture has already started."
        case .notRecording:
            return "Live audio capture has not started."
        case .conversionSetupFailed:
            return "Could not configure live audio conversion."
        case .engineStartFailed(let message):
            return "Could not start live audio capture: \(message)"
        case .fileWriteFailed(let message):
            return "Could not write fallback audio file: \(message)"
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        if let encoded = string.data(using: .ascii) {
            append(encoded)
        }
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }
}
