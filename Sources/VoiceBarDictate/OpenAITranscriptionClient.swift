import Foundation

struct OpenAITranscriptionClient {
    private static let transcriptionsPath = "/v1/audio/transcriptions"

    func transcribe(
        fileURL: URL,
        apiKey: String,
        baseURL: String,
        model: String,
        prompt: String?,
        language: String?
    ) async throws -> String {
        let normalizedBaseURL = Self.normalizeBaseURL(baseURL)
        guard let endpoint = URL(string: normalizedBaseURL + Self.transcriptionsPath) else {
            throw TranscriptionError.invalidBaseURL(baseURL)
        }

        // Stream the multipart body from disk instead of holding the whole recording in memory.
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFileURL = try MultipartFormBody(
            boundary: boundary,
            fields: Self.formFields(model: model, prompt: prompt, language: language),
            file: .init(fieldName: "file", fileURL: fileURL, contentType: "audio/m4a")
        ).writeToTemporaryFile()
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFileURL)
        guard let response = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard (200..<300).contains(response.statusCode) else {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                if
                    let suggestedBaseURL = Self.suggestedRegionalBaseURL(from: apiError.error.message),
                    URL(string: suggestedBaseURL)?.host?.lowercased() != URL(string: normalizedBaseURL)?.host?.lowercased(),
                    let retryEndpoint = URL(string: suggestedBaseURL + Self.transcriptionsPath)
                {
                    var retryRequest = request
                    retryRequest.url = retryEndpoint

                    let (retryData, retryResponse) = try await URLSession.shared.upload(for: retryRequest, fromFile: bodyFileURL)
                    guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                        throw TranscriptionError.invalidResponse
                    }

                    if (200..<300).contains(retryHTTPResponse.statusCode) {
                        let retryResult = try JSONDecoder().decode(TranscriptionResponse.self, from: retryData)
                        return retryResult.text
                    }

                    if let retryAPIError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: retryData) {
                        let retryMessage = Self.appendRegionalHintIfNeeded(
                            retryAPIError.error.message,
                            currentBaseURL: suggestedBaseURL
                        )
                        throw TranscriptionError.apiError(retryMessage)
                    }

                    throw TranscriptionError.httpError(retryHTTPResponse.statusCode)
                }

                let message = Self.appendRegionalHintIfNeeded(apiError.error.message, currentBaseURL: normalizedBaseURL)
                throw TranscriptionError.apiError(message)
            }
            throw TranscriptionError.httpError(response.statusCode)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    static func normalizeBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? SettingsStore.defaultAPIBaseURL : trimmed
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static func formFields(model: String, prompt: String?, language: String?) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [
            ("model", model),
            ("response_format", "json")
        ]

        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            fields.append(("prompt", prompt))
        }

        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            // OpenAI expects an ISO-639-1 code, so "en-GB" is sent as "en".
            let languageCode = Locale.Language(identifier: language).languageCode?.identifier ?? language
            fields.append(("language", languageCode))
        }

        return fields
    }

    static func appendRegionalHintIfNeeded(_ message: String, currentBaseURL: String) -> String {
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

    static func suggestedRegionalBaseURL(from message: String) -> String? {
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
}

/// Writes a `multipart/form-data` body to a temporary file, copying the attached file in chunks.
struct MultipartFormBody {
    struct FilePart {
        var fieldName: String
        var fileURL: URL
        var contentType: String
    }

    var boundary: String
    var fields: [(name: String, value: String)]
    var file: FilePart

    func writeToTemporaryFile() throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceBarDictate-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }

            var header = ""
            for field in fields {
                header += "--\(boundary)\r\n"
                header += "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
                header += "\(field.value)\r\n"
            }
            header += "--\(boundary)\r\n"
            header += "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileURL.lastPathComponent)\"\r\n"
            header += "Content-Type: \(file.contentType)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))

            let input = try FileHandle(forReadingFrom: file.fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }

            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        return bodyURL
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
