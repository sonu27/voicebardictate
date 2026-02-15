import Foundation

final class SettingsStore {
    private enum DefaultsKey {
        static let apiBaseURL = "settings.apiBaseURL"
        static let model = "settings.model"
        static let language = "settings.language"
        static let prompt = "settings.prompt"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainService
    private let apiKeyAccount = "openai.api.key"

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
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

    func loadAPIKey() -> String {
        keychain.read(account: apiKeyAccount) ?? ""
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: apiKeyAccount)
            return
        }
        keychain.save(trimmed, account: apiKeyAccount)
    }
}
