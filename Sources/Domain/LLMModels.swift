import Foundation

public struct OptionalLLMConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let model: String
    public let apiKey: String?

    public init(endpoint: URL, model: String, apiKey: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
    }
}

public struct LLMGenerationRequest: Sendable, Equatable {
    public let transcript: String
    public let instruction: String

    public init(transcript: String, instruction: String) {
        self.transcript = transcript
        self.instruction = instruction
    }
}

public struct LLMGenerationResult: Sendable, Equatable {
    public let text: String
    public let providerHost: String
    public let model: String
    public let processedRemotely: Bool

    public init(text: String, providerHost: String, model: String, processedRemotely: Bool) {
        self.text = text
        self.providerHost = providerHost
        self.model = model
        self.processedRemotely = processedRemotely
    }
}
