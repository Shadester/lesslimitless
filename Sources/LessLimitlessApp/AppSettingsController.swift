import Combine
import Domain
import Foundation
import Security

@MainActor
final class AppSettingsController: ObservableObject {
    @Published var whisperExecutablePath: String { didSet { defaults.set(whisperExecutablePath, forKey: Keys.whisperExecutable) } }
    @Published var whisperModelPath: String { didSet { defaults.set(whisperModelPath, forKey: Keys.whisperModel) } }
    @Published var llmEndpoint: String { didSet { defaults.set(llmEndpoint, forKey: Keys.llmEndpoint) } }
    @Published var llmModel: String { didSet { defaults.set(llmModel, forKey: Keys.llmModel) } }
    @Published var providerKeyDraft = ""
    @Published private(set) var statusMessage: String?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let whisperExecutable = "LessLimitless.whisperExecutable"
        static let whisperModel = "LessLimitless.whisperModel"
        static let llmEndpoint = "LessLimitless.llmEndpoint"
        static let llmModel = "LessLimitless.llmModel"
        static let providerKeyAccount = "optional-llm-api-key"
        static let service = "app.lesslimitless"
    }

    init() {
        whisperExecutablePath = defaults.string(forKey: Keys.whisperExecutable) ?? ""
        whisperModelPath = defaults.string(forKey: Keys.whisperModel) ?? ""
        llmEndpoint = defaults.string(forKey: Keys.llmEndpoint) ?? "http://localhost:11434/v1/chat/completions"
        llmModel = defaults.string(forKey: Keys.llmModel) ?? ""
        providerKeyDraft = Keychain.value(service: Keys.service, account: Keys.providerKeyAccount) ?? ""
    }

    func saveProviderKey() {
        do {
            try Keychain.save(providerKeyDraft, service: Keys.service, account: Keys.providerKeyAccount)
            statusMessage = "Provider key saved in Keychain"
        } catch {
            statusMessage = "Could not save provider key"
        }
    }
    var llmConfiguration: OptionalLLMConfiguration? {
        guard let endpoint = URL(string: llmEndpoint), !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return OptionalLLMConfiguration(endpoint: endpoint, model: llmModel, apiKey: providerKeyDraft.isEmpty ? nil : providerKeyDraft)
    }

    var transcriptionJobTemplate: LocalTranscriptionJob? {
        guard let executable = URL(string: whisperExecutablePath), let model = URL(string: whisperModelPath) else { return nil }
        return LocalTranscriptionJob.whisperCPP(executableURL: executable, modelURL: model, audioURL: URL(fileURLWithPath: "/placeholder.wav"))
    }
}
private enum Keychain {
    static func value(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        } else if status != errSecSuccess {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
