import Foundation

final class SettingsStore {
    private enum DefaultsKey {
        static let apiBaseURL = "settings.apiBaseURL"
        static let model = "settings.model"
        static let openAIModelID = "settings.openAIModelID"
        static let language = "settings.language"
        static let prompt = "settings.prompt"
        static let startAtLogin = "settings.startAtLogin"
        static let hotkey = "settings.hotkey"
        static let hotkeyMode = "settings.hotkeyMode"
    }

    static let defaultAPIBaseURL = "https://api.openai.com"

    private let defaults: UserDefaults
    private let keychain: KeychainService
    private let legacyKeychain: KeychainService
    private let apiKeyAccount = "openai.api.key"
    private let dotEnvAPIKey: String?

    /// Set when an earlier version's stored OpenAI model ID was replaced on launch.
    private(set) var migratedLegacyModelID: String?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainService = KeychainService(),
        legacyKeychain: KeychainService = KeychainService(service: KeychainService.legacyService),
        loadsDotEnv: Bool = SettingsStore.dotEnvEnabled
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.legacyKeychain = legacyKeychain
        self.dotEnvAPIKey = loadsDotEnv
            ? Self.findDotEnvFileURL().flatMap { DotEnv.value(for: "OPENAI_API_KEY", inFileAt: $0) }
            : nil
        migrateLegacyModelIfNeeded()
    }

    /// `.env` overrides are a development convenience. Release builds launched from Finder run with
    /// a working directory of `/`, so searching parent folders there could silently replace the Keychain key.
    static var dotEnvEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var model: TranscriptionModel {
        get {
            defaults.string(forKey: DefaultsKey.model).flatMap(TranscriptionModel.init(rawValue:)) ?? .gptTranscribe
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.model)
        }
    }

    var openAIModelID: String {
        get {
            let saved = defaults.string(forKey: DefaultsKey.openAIModelID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return saved.isEmpty ? TranscriptionModel.defaultOpenAIModelID : saved
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.openAIModelID)
        }
    }

    var apiBaseURL: String {
        get {
            defaults.string(forKey: DefaultsKey.apiBaseURL) ?? Self.defaultAPIBaseURL
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

    var hotkey: Hotkey {
        get {
            guard
                let data = defaults.data(forKey: DefaultsKey.hotkey),
                let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data)
            else {
                return .default
            }
            return hotkey
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: DefaultsKey.hotkey)
        }
    }

    var hotkeyMode: HotkeyMode {
        get {
            defaults.string(forKey: DefaultsKey.hotkeyMode).flatMap(HotkeyMode.init(rawValue:)) ?? .toggle
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.hotkeyMode)
        }
    }

    var isUsingDotEnvAPIKey: Bool {
        dotEnvAPIKey != nil
    }

    func loadAPIKey() -> String {
        if let dotEnvAPIKey {
            return dotEnvAPIKey
        }
        if let key = keychain.read(account: apiKeyAccount) {
            return key
        }
        return migrateLegacyAPIKey() ?? ""
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

    /// Moves a key saved under the old placeholder Keychain service to the current one.
    private func migrateLegacyAPIKey() -> String? {
        guard let legacyKey = legacyKeychain.read(account: apiKeyAccount) else {
            return nil
        }
        do {
            try keychain.save(legacyKey, account: apiKeyAccount)
            try? legacyKeychain.delete(account: apiKeyAccount)
        } catch {
            // Keep the legacy item so the key is not lost; it is still returned for this launch.
        }
        return legacyKey
    }

    /// Earlier versions stored the OpenAI model ID (e.g. `gpt-4o-mini-transcribe`) as the model setting.
    /// Those models are retired, so map them to the OpenAI engine with the current default model ID.
    private func migrateLegacyModelIfNeeded() {
        guard
            let saved = defaults.string(forKey: DefaultsKey.model),
            TranscriptionModel(rawValue: saved) == nil
        else {
            return
        }
        defaults.set(TranscriptionModel.gptTranscribe.rawValue, forKey: DefaultsKey.model)
        if TranscriptionModel.legacyOpenAIModelIDs.contains(saved) {
            migratedLegacyModelID = saved
        }
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

/// Minimal `.env` reader: `KEY=value`, optional `export`, quotes, and trailing `#` comments.
enum DotEnv {
    static func value(for key: String, inFileAt url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return value(for: key, in: contents)
    }

    static func value(for key: String, in contents: String) -> String? {
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

            let lineKey = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineKey == key else {
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
}
