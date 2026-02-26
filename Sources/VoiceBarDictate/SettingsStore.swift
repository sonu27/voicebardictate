import Foundation

final class SettingsStore {
    private enum DefaultsKey {
        static let apiBaseURL = "settings.apiBaseURL"
        static let model = "settings.model"
        static let language = "settings.language"
        static let prompt = "settings.prompt"
        static let startAtLogin = "settings.startAtLogin"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainService
    private let apiKeyAccount = "openai.api.key"
    private let dotEnvAPIKey: String?

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
        let dotEnvFileURL = Self.findDotEnvFileURL()
        self.dotEnvAPIKey = dotEnvFileURL.flatMap { Self.loadAPIKeyFromDotEnv(at: $0) }
    }

    var model: String {
        get {
            defaults.string(forKey: DefaultsKey.model) ?? "gpt-4o-mini-transcribe"
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.model)
        }
    }

    var apiBaseURL: String {
        get {
            defaults.string(forKey: DefaultsKey.apiBaseURL) ?? "https://api.openai.com"
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.apiBaseURL)
        }
    }

    var language: String {
        get {
            defaults.string(forKey: DefaultsKey.language) ?? ""
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.language)
        }
    }

    var prompt: String {
        get {
            defaults.string(forKey: DefaultsKey.prompt) ?? ""
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.prompt)
        }
    }

    var startAtLogin: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.startAtLogin)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.startAtLogin)
        }
    }

    var isUsingDotEnvAPIKey: Bool {
        dotEnvAPIKey != nil
    }

    func loadAPIKey() -> String {
        if let dotEnvAPIKey {
            return dotEnvAPIKey
        }
        return keychain.read(account: apiKeyAccount) ?? ""
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if dotEnvAPIKey != nil {
            // .env key is authoritative; skip Keychain writes to avoid prompts during local iteration.
            return
        }

        if trimmed.isEmpty {
            try keychain.delete(account: apiKeyAccount)
            return
        }
        try keychain.save(trimmed, account: apiKeyAccount)
    }

    private static func loadAPIKeyFromDotEnv(at url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "OPENAI_API_KEY" else {
                continue
            }

            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if let commentIndex = value.firstIndex(of: "#") {
                value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        return nil
    }

    private static func findDotEnvFileURL() -> URL? {
        var directoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while true {
            let candidateURL = directoryURL.appendingPathComponent(".env", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            if parentURL.path == directoryURL.path {
                break
            }
            directoryURL = parentURL
        }

        return nil
    }
}
