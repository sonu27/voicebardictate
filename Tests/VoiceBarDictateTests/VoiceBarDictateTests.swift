import AVFoundation
import Carbon
import Foundation
import Testing
@testable import VoiceBarDictate

@Suite("DotEnv parsing")
struct DotEnvTests {
    @Test func readsPlainValue() {
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: "OPENAI_API_KEY=sk-test") == "sk-test")
    }

    @Test func handlesExportQuotesAndComments() {
        let contents = """
        # comment
        export OTHER=1
        export OPENAI_API_KEY="sk-quoted # not a comment"
        """
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: contents) == "sk-quoted # not a comment")
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: "OPENAI_API_KEY=sk-bare # trailing") == "sk-bare")
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: "OPENAI_API_KEY='single'") == "single")
    }

    @Test func ignoresMissingOrEmptyValues() {
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: "OTHER=1") == nil)
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: "OPENAI_API_KEY=") == nil)
        #expect(DotEnv.value(for: "OPENAI_API_KEY", in: "OPENAI_API_KEY=\"\"") == nil)
    }
}

@Suite("OpenAI request building")
struct OpenAIRequestTests {
    @Test func normalizesBaseURL() {
        #expect(OpenAITranscriptionClient.normalizeBaseURL("") == "https://api.openai.com")
        #expect(OpenAITranscriptionClient.normalizeBaseURL("  https://eu.api.openai.com/ ") == "https://eu.api.openai.com")
    }

    @Test func suggestsRegionalEndpointFromErrorMessage() {
        let message = "This project is restricted to project geography EU. Use the regional endpoint."
        #expect(OpenAITranscriptionClient.suggestedRegionalBaseURL(from: message) == "https://eu.api.openai.com")
        #expect(OpenAITranscriptionClient.suggestedRegionalBaseURL(from: "project geography XX") == nil)
        #expect(OpenAITranscriptionClient.suggestedRegionalBaseURL(from: "Invalid API key") == nil)
    }

    @Test func appendsRegionalHintOnlyWhenHostDiffers() {
        let message = "Wrong region for project geography US"
        #expect(
            OpenAITranscriptionClient.appendRegionalHintIfNeeded(message, currentBaseURL: "https://api.openai.com")
                == "\(message). Set API Base URL to https://us.api.openai.com."
        )
        #expect(
            OpenAITranscriptionClient.appendRegionalHintIfNeeded(message, currentBaseURL: "https://us.api.openai.com")
                == message
        )
    }

    @Test func formFieldsTrimAndReduceLanguageToISO639() {
        let fields = OpenAITranscriptionClient.formFields(model: "gpt-transcribe", prompt: "  ", language: " en-GB ")
        let dictionary = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })
        #expect(dictionary["model"] == "gpt-transcribe")
        #expect(dictionary["response_format"] == "json")
        #expect(dictionary["prompt"] == nil)
        #expect(dictionary["language"] == "en")
    }

    @Test func multipartBodyContainsFieldsAndFileBytes() throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let audioBytes = Data((0..<1_000).map { UInt8($0 % 256) })
        try audioBytes.write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let bodyURL = try MultipartFormBody(
            boundary: "B",
            fields: [("model", "gpt-transcribe")],
            file: .init(fieldName: "file", fileURL: audioURL, contentType: "audio/m4a")
        ).writeToTemporaryFile()
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let body = try Data(contentsOf: bodyURL)
        let header = Data("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: audio/m4a\r\n\r\n".utf8)
        let footer = Data("\r\n--B--\r\n".utf8)
        #expect(body == header + audioBytes + footer)
    }
}

@Suite("Hotkey")
struct HotkeyTests {
    @Test func defaultIsControlOptionSpace() {
        #expect(Hotkey.default.displayString == "Control + Option + Space")
        #expect(Hotkey.default.keyCode == UInt32(kVK_Space))
        #expect(Hotkey.default.menuKeyboardShortcut != nil)
    }

    @Test func recordsLetterWithModifiers() throws {
        let hotkey = try Hotkey.make(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift], characters: "d").get()
        #expect(hotkey.displayString == "Shift + Command + D")
        #expect(hotkey.carbonModifiers == UInt32(cmdKey) | UInt32(shiftKey))
    }

    @Test func rejectsReservedKeysAndBareLetters() {
        #expect(Hotkey.make(keyCode: UInt16(kVK_Escape), modifiers: [.control], characters: nil) == .failure(.reservedKey("Escape")))
        #expect(Hotkey.make(keyCode: UInt16(kVK_Return), modifiers: [.command], characters: nil) == .failure(.reservedKey("Return")))
        #expect(Hotkey.make(keyCode: UInt16(kVK_ANSI_D), modifiers: [], characters: "d") == .failure(.missingModifier))
        #expect(Hotkey.make(keyCode: UInt16(kVK_ANSI_D), modifiers: [.shift], characters: "d") == .failure(.missingModifier))
    }

    @Test func allowsBareFunctionKey() throws {
        let hotkey = try Hotkey.make(keyCode: UInt16(kVK_F5), modifiers: [], characters: nil).get()
        #expect(hotkey.displayString == "F5")
        #expect(hotkey.menuKeyboardShortcut == nil)
    }
}

@Suite("Settings persistence")
struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "VoiceBarDictateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func migratesRetiredModelIDs() {
        let defaults = makeDefaults()
        defaults.set("gpt-4o-mini-transcribe", forKey: "settings.model")

        let store = SettingsStore(defaults: defaults, loadsDotEnv: false)
        #expect(store.model == .gptTranscribe)
        #expect(store.openAIModelID == TranscriptionModel.defaultOpenAIModelID)
        #expect(store.migratedLegacyModelID == "gpt-4o-mini-transcribe")
        #expect(defaults.string(forKey: "settings.model") == TranscriptionModel.gptTranscribe.rawValue)
    }

    @Test func keepsCurrentEngineWithoutMigrationNotice() {
        let defaults = makeDefaults()
        defaults.set(TranscriptionModel.appleOnDevice.rawValue, forKey: "settings.model")

        let store = SettingsStore(defaults: defaults, loadsDotEnv: false)
        #expect(store.model == .appleOnDevice)
        #expect(store.migratedLegacyModelID == nil)
    }

    @Test func persistsHotkeyModeAndModelID() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults, loadsDotEnv: false)
        #expect(store.hotkey == .default)
        #expect(store.hotkeyMode == .toggle)

        let custom = Hotkey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey), keyLabel: "D")
        store.hotkey = custom
        store.hotkeyMode = .hold
        store.openAIModelID = "  gpt-4o-transcribe  "

        let reloaded = SettingsStore(defaults: defaults, loadsDotEnv: false)
        #expect(reloaded.hotkey == custom)
        #expect(reloaded.hotkeyMode == .hold)
        #expect(reloaded.openAIModelID == "gpt-4o-transcribe")
    }

    @Test func dotEnvIsOffWhenDisabled() {
        let store = SettingsStore(defaults: makeDefaults(), loadsDotEnv: false)
        #expect(!store.isUsingDotEnvAPIKey)
    }
}

@Suite("Audio pipeline")
struct AudioPipelineTests {
    private static func sineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate))
            }
        }
        return buffer
    }

    @Test func meterMapsSilenceAndLoudSignal() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        #expect(RecordingSink.normalizedLevel(of: Self.sineBuffer(format: format, frames: 4_800, amplitude: 0)) == 0)
        #expect(RecordingSink.normalizedLevel(of: Self.sineBuffer(format: format, frames: 4_800, amplitude: 1)) > 0.9)
    }

    @Test func smoothingRisesFasterThanItFalls() {
        let rise = AppState.smoothedLevel(previous: 0, next: 1)
        let fall = 1 - AppState.smoothedLevel(previous: 1, next: 0)
        #expect(rise > fall)
    }

    @Test func converterResamplesToTargetRate() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = try #require(PCMConverter(from: input, to: output))

        var frames: AVAudioFrameCount = 0
        for _ in 0..<10 {
            if let converted = converter.convert(Self.sineBuffer(format: input, frames: 4_800)) {
                #expect(converted.format == output)
                frames += converted.frameLength
            }
        }
        // 48,000 input frames at 3:1 is about 16,000 output frames, minus resampler latency.
        #expect(frames > 15_000 && frames <= 16_000)
    }

    @Test func sinkWritesPlayableM4A() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = try RecordingSink(inputFormat: input, fileURL: url, buffersUntilHandlerAttached: false)
        for _ in 0..<10 {
            sink.process(Self.sineBuffer(format: input, frames: 4_800))
        }
        #expect(sink.finishFile() == url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length > 10_000)
    }

    @Test func heldBuffersAreDeliveredInOrderOnAttach() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let sink = try! RecordingSink(inputFormat: format, fileURL: nil, buffersUntilHandlerAttached: true)

        sink.process(Self.sineBuffer(format: format, frames: 100))
        sink.process(Self.sineBuffer(format: format, frames: 200))

        let received = LockedArray()
        sink.attachBufferHandler { buffer in received.append(buffer.frameLength) }
        sink.process(Self.sineBuffer(format: format, frames: 300))

        #expect(received.values == [100, 200, 300])
    }
}

private final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AVAudioFrameCount] = []

    func append(_ value: AVAudioFrameCount) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [AVAudioFrameCount] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("Interface formatting")
struct InterfaceFormattingTests {
    @Test func keyCapsFollowMenuOrder() {
        #expect(Hotkey.default.keyCapLabels == ["⌃", "⌥", "Space"])

        let all = Hotkey(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey),
            keyLabel: "D"
        )
        #expect(all.keyCapLabels == ["⌃", "⌥", "⇧", "⌘", "D"])
    }

    @Test func elapsedTime() {
        #expect(DictationFormat.elapsed(0) == "0:00")
        #expect(DictationFormat.elapsed(7.9) == "0:07")
        #expect(DictationFormat.elapsed(102) == "1:42")
        #expect(DictationFormat.elapsed(725) == "12:05")
        #expect(DictationFormat.elapsed(-3) == "0:00")
    }

    @Test func relativeTimeSaysJustNowUnderAMinute() {
        let now = Date()
        #expect(DictationFormat.relative(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(DictationFormat.relative(now.addingTimeInterval(-120), now: now) != "just now")
    }
}

@Suite("Silence detection")
struct SilenceDetectorTests {
    @Test func warnsOnlyAfterGracePeriodWithNoSound() {
        let start = Date()
        var detector = SilenceDetector(startedAt: start)
        #expect(detector.update(level: 0, at: start.addingTimeInterval(1)) == false)
        #expect(detector.update(level: 0.01, at: start.addingTimeInterval(3.9)) == false)
        #expect(detector.update(level: 0, at: start.addingTimeInterval(4)) == true)
    }

    @Test func neverWarnsOnceSoundWasHeard() {
        let start = Date()
        var detector = SilenceDetector(startedAt: start)
        #expect(detector.update(level: 0.4, at: start.addingTimeInterval(0.5)) == false)
        #expect(detector.update(level: 0, at: start.addingTimeInterval(10)) == false)
    }

    @Test func soundAfterWarningClearsIt() {
        let start = Date()
        var detector = SilenceDetector(startedAt: start)
        #expect(detector.update(level: 0, at: start.addingTimeInterval(5)) == true)
        #expect(detector.update(level: 0.3, at: start.addingTimeInterval(6)) == false)
    }
}

@Suite("Live text tail")
struct LiveTextTailTests {
    @Test func shortTextIsUnchanged() {
        #expect(DictationFormat.tail("Hello world", maxCharacters: 20) == "Hello world")
    }

    @Test func longTextKeepsNewestWholeWords() {
        let text = "one two three four five six seven"
        #expect(DictationFormat.tail(text, maxCharacters: 12) == "…six seven")
    }
}

@Suite("Accessibility prompt")
struct AccessibilityPromptTests {
    @Test func promptFlagPersists() {
        let suite = "VoiceBarDictateTests.prompt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults, loadsDotEnv: false)
        #expect(store.hasShownAccessibilityPrompt == false)
        store.hasShownAccessibilityPrompt = true
        #expect(SettingsStore(defaults: defaults, loadsDotEnv: false).hasShownAccessibilityPrompt)
    }
}
