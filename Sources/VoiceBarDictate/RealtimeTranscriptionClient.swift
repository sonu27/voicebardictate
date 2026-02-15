import Foundation

actor RealtimeTranscriptionClient {
    enum Event: Sendable {
        case committed(itemID: String, previousItemID: String?)
        case delta(itemID: String, text: String)
        case completed(itemID: String, text: String)
        case failed(message: String)
        case disconnected(message: String)
    }

    typealias EventHandler = @Sendable (Event) -> Void

    private let session: URLSession = .shared
    private let debugLogger = DebugLogger.shared
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var completionWaitContinuation: CheckedContinuation<Bool, Never>?
    private var didReceiveCompletion = false
    private var isConnectionUsable = false
    private var hasLoggedSendFailure = false

    func connect(
        apiKey: String,
        baseURL: String,
        model: String,
        prompt: String?,
        language: String?,
        eventHandler: @escaping EventHandler
    ) async throws {
        disconnect()
        self.eventHandler = eventHandler
        didReceiveCompletion = false
        isConnectionUsable = false
        hasLoggedSendFailure = false

        let sessionModel = preferredRealtimeTranscriptionModel(for: model)
        let endpoint = try realtimeEndpoint(baseURL: baseURL)
        debugLogger.info(
            "Connecting realtime websocket. endpointHost=\(endpoint.host ?? "nil"), sessionModel=\(sessionModel), selectedModel=\(model), promptSet=\(!(prompt ?? "").isEmpty), languageSet=\(!(language ?? "").isEmpty)",
            category: "realtime"
        )
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        receiveLoopTask = Task { [weak task] in
            guard let task else { return }
            await self.receiveLoop(task: task)
        }

        try await sendJSON(buildTranscriptionSessionUpdatePayload(model: sessionModel, prompt: prompt, language: language))
        isConnectionUsable = true
        debugLogger.info("Realtime transcription_session.update sent.", category: "realtime")
    }

    func sendAudioChunk(_ chunk: Data) async throws {
        guard !chunk.isEmpty else { return }
        guard isConnectionUsable, task != nil else { return }

        try await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": chunk.base64EncodedString()
        ])
    }

    func finalize() async throws {
        guard isConnectionUsable, task != nil else { return }
        try await sendJSON([
            "type": "input_audio_buffer.commit"
        ])
        debugLogger.info("Realtime input buffer commit sent.", category: "realtime")
    }

    func waitForCompletion(timeoutNanoseconds: UInt64) async -> Bool {
        if didReceiveCompletion {
            return true
        }

        return await withCheckedContinuation { continuation in
            completionWaitContinuation = continuation
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.resolveCompletionWait(with: false)
            }
        }
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnectionUsable = false
        hasLoggedSendFailure = false
        eventHandler = nil
        resolveCompletionWait(with: false)
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleMessagePayload(Data(text.utf8))
                case .data(let data):
                    handleMessagePayload(data)
                @unknown default:
                    continue
                }
            } catch {
                isConnectionUsable = false
                eventHandler?(.disconnected(message: error.localizedDescription))
                debugLogger.warning("Realtime receive loop ended: \(error.localizedDescription)", category: "realtime")
                resolveCompletionWait(with: false)
                return
            }
        }
    }

    private func handleMessagePayload(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any],
            let type = payload["type"] as? String
        else {
            debugLogger.warning("Realtime payload parse failed. bytes=\(data.count)", category: "realtime")
            return
        }

        switch type {
        case "input_audio_buffer.committed":
            guard let itemID = firstString(in: payload, matching: ["item_id"]) else { return }
            let previousItemID = firstString(in: payload, matching: ["previous_item_id"])
            eventHandler?(.committed(itemID: itemID, previousItemID: previousItemID))

        case "conversation.item.input_audio_transcription.delta":
            guard
                let itemID = firstString(in: payload, matching: ["item_id"]),
                let delta = firstString(in: payload, matching: ["delta"])
            else {
                return
            }
            eventHandler?(.delta(itemID: itemID, text: delta))

        case "conversation.item.input_audio_transcription.completed":
            guard
                let itemID = firstString(in: payload, matching: ["item_id"])
            else {
                return
            }

            let transcript = firstString(in: payload, matching: ["transcript", "text"]) ?? ""
            didReceiveCompletion = true
            eventHandler?(.completed(itemID: itemID, text: transcript))
            resolveCompletionWait(with: true)

        case "conversation.item.input_audio_transcription.failed":
            let message = firstString(in: payload, matching: ["message"]) ?? "Realtime transcription failed."
            isConnectionUsable = false
            eventHandler?(.failed(message: message))
            debugLogger.error("Realtime transcription failed event received.", category: "realtime")
            resolveCompletionWait(with: false)

        case "error":
            let message = firstString(in: payload, matching: ["message"]) ?? "Realtime connection error."
            isConnectionUsable = false
            eventHandler?(.failed(message: message))
            debugLogger.error("Realtime error event received.", category: "realtime")
            resolveCompletionWait(with: false)

        default:
            break
        }
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let task else {
            throw RealtimeTranscriptionError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeTranscriptionError.serializationFailed
        }

        do {
            try await task.send(.string(text))
        } catch {
            isConnectionUsable = false
            if !hasLoggedSendFailure {
                debugLogger.error("Realtime send failed: \(error.localizedDescription)", category: "realtime")
                hasLoggedSendFailure = true
            }
            throw RealtimeTranscriptionError.sendFailed(error.localizedDescription)
        }
    }

    private func realtimeEndpoint(baseURL: String) throws -> URL {
        let normalizedBaseURL = normalizeBaseURL(baseURL)
        guard var components = URLComponents(string: normalizedBaseURL + "/v1/realtime") else {
            throw RealtimeTranscriptionError.invalidBaseURL(baseURL)
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        default:
            components.scheme = "wss"
        }

        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription")
        ]

        guard let url = components.url else {
            throw RealtimeTranscriptionError.invalidBaseURL(baseURL)
        }
        return url
    }

    private func normalizeBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? "https://api.openai.com" : trimmed
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private func buildTranscriptionSessionUpdatePayload(model: String, prompt: String?, language: String?) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": model
        ]

        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcription["prompt"] = prompt
        }

        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcription["language"] = language
        }

        return [
            "type": "transcription_session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": transcription,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]
    }

    private func preferredRealtimeTranscriptionModel(for model: String) -> String {
        if model == "gpt-4o-mini-transcribe" {
            return "gpt-4o-transcribe"
        }
        return model
    }

    private func resolveCompletionWait(with value: Bool) {
        guard let continuation = completionWaitContinuation else { return }
        completionWaitContinuation = nil
        continuation.resume(returning: value)
    }

    private func firstString(in object: Any, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let stringValue = value as? String, !stringValue.isEmpty {
                    return stringValue
                }
                if let nested = firstString(in: value, matching: keys) {
                    return nested
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for entry in array {
                if let nested = firstString(in: entry, matching: keys) {
                    return nested
                }
            }
        }

        return nil
    }
}

enum RealtimeTranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case notConnected
    case serializationFailed
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid Realtime base URL: \(baseURL)"
        case .notConnected:
            return "Realtime transcription is not connected."
        case .serializationFailed:
            return "Could not encode Realtime payload."
        case .sendFailed(let message):
            return "Could not send Realtime payload: \(message)"
        }
    }
}
