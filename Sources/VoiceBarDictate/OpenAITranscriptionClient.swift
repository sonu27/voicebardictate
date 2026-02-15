import Foundation

struct OpenAITranscriptionClient {
    func transcribe(
        fileURL: URL,
        apiKey: String,
        baseURL: String,
        model: String,
        prompt: String?,
        language: String?
    ) async throws -> String {
        let normalizedBaseURL = normalizeBaseURL(baseURL)
        guard let endpoint = URL(string: normalizedBaseURL + "/v1/audio/transcriptions") else {
            throw TranscriptionError.invalidBaseURL(baseURL)
        }

        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)

        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildBody(
            boundary: boundary,
            model: model,
            prompt: prompt,
            language: language,
            fileName: fileURL.lastPathComponent,
            audioData: audioData
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard (200..<300).contains(response.statusCode) else {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                if
                    let suggestedBaseURL = suggestedRegionalBaseURL(from: apiError.error.message),
                    URL(string: suggestedBaseURL)?.host?.lowercased() != URL(string: normalizedBaseURL)?.host?.lowercased(),
                    let retryEndpoint = URL(string: suggestedBaseURL + "/v1/audio/transcriptions")
                {
                    var retryRequest = request
                    retryRequest.url = retryEndpoint

                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                        throw TranscriptionError.invalidResponse
                    }

                    if (200..<300).contains(retryHTTPResponse.statusCode) {
                        let retryResult = try JSONDecoder().decode(TranscriptionResponse.self, from: retryData)
                        return retryResult.text
                    }

                    if let retryAPIError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: retryData) {
                        let retryMessage = appendRegionalHintIfNeeded(
                            retryAPIError.error.message,
                            currentBaseURL: suggestedBaseURL
                        )
                        throw TranscriptionError.apiError(retryMessage)
                    }

                    throw TranscriptionError.httpError(retryHTTPResponse.statusCode)
                }

                let message = appendRegionalHintIfNeeded(apiError.error.message, currentBaseURL: normalizedBaseURL)
                throw TranscriptionError.apiError(message)
            }
            throw TranscriptionError.httpError(response.statusCode)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    private func normalizeBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? "https://api.openai.com" : trimmed
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private func appendRegionalHintIfNeeded(_ message: String, currentBaseURL: String) -> String {
        guard let suggestedBaseURL = suggestedRegionalBaseURL(from: message) else {
            return message
        }

        let currentHost = URL(string: currentBaseURL)?.host?.lowercased()
        let suggestedHost = URL(string: suggestedBaseURL)?.host?.lowercased()
        guard currentHost != suggestedHost else {
            return message
        }

        return "\(message). Set API Base URL to \(suggestedBaseURL)."
    }

    private func suggestedRegionalBaseURL(from message: String) -> String? {
        let marker = "project geography "
        guard let range = message.range(of: marker, options: .caseInsensitive) else {
            return nil
        }

        let geographyFragment = message[range.upperBound...]
        guard let code = geographyFragment.split(whereSeparator: { !$0.isLetter }).first?.uppercased() else {
            return nil
        }

        let hostByCode: [String: String] = [
            "AU": "au.api.openai.com",
            "CA": "ca.api.openai.com",
            "EU": "eu.api.openai.com",
            "IN": "in.api.openai.com",
            "JP": "jp.api.openai.com",
            "KR": "kr.api.openai.com",
            "SG": "sg.api.openai.com",
            "US": "us.api.openai.com"
        ]

        guard let host = hostByCode[code] else {
            return nil
        }

        return "https://\(host)"
    }

    private func buildBody(
        boundary: String,
        model: String,
        prompt: String?,
        language: String?,
        fileName: String,
        audioData: Data
    ) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        appendField("model", model)
        appendField("response_format", "json")

        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField("prompt", prompt)
        }

        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField("language", language)
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        return body
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: OpenAIErrorPayload
}

private struct OpenAIErrorPayload: Decodable {
    let message: String
}

enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid API base URL: \(baseURL)"
        case .invalidResponse:
            return "OpenAI API returned an invalid HTTP response."
        case .httpError(let statusCode):
            return "OpenAI API request failed with status code \(statusCode)."
        case .apiError(let message):
            return "OpenAI API error: \(message)"
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
