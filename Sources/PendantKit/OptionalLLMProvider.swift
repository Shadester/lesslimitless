import Domain
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OptionalLLMProviderError: Error, Equatable, Sendable {
    case invalidEndpoint
    case prohibitedEndpoint
    case transcriptTooLarge
    case transportFailed
    case httpFailure(Int)
    case malformedResponse
}

public protocol OptionalLLMTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionOptionalLLMTransport: OptionalLLMTransport {
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OptionalLLMProviderError.transportFailed }
        return (data, http)
    }
}

/// Explicit opt-in OpenAI-compatible text provider. It never accepts audio,
/// never configures a Limitless host, and permits HTTP only on loopback hosts.
public struct OptionalLLMProvider {
    public static let maximumTranscriptBytes = 2 * 1_024 * 1_024
    private let transport: any OptionalLLMTransport

    public init(transport: any OptionalLLMTransport = URLSessionOptionalLLMTransport()) {
        self.transport = transport
    }

    public func generate(
        _ request: LLMGenerationRequest,
        configuration: OptionalLLMConfiguration
    ) async throws -> LLMGenerationResult {
        let endpoint = try validate(configuration)
        guard request.transcript.lengthOfBytes(using: .utf8) <= Self.maximumTranscriptBytes else {
            throw OptionalLLMProviderError.transcriptTooLarge
        }
        let body = ChatRequest(
            model: configuration.model,
            messages: [
                Message(role: "system", content: request.instruction),
                Message(role: "user", content: request.transcript)
            ]
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(urlRequest) }
        catch { throw OptionalLLMProviderError.transportFailed }
        guard (200..<300).contains(response.statusCode) else {
            throw OptionalLLMProviderError.httpFailure(response.statusCode)
        }
        guard let content = try? JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OptionalLLMProviderError.malformedResponse
        }
        let host = endpoint.host?.lowercased() ?? ""
        return LLMGenerationResult(
            text: content,
            providerHost: host,
            model: configuration.model,
            processedRemotely: !Self.isLoopback(host)
        )
    }

    private func validate(_ configuration: OptionalLLMConfiguration) throws -> URL {
        let url = configuration.endpoint
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw OptionalLLMProviderError.invalidEndpoint
        }
        guard !host.contains("limitless") else { throw OptionalLLMProviderError.prohibitedEndpoint }
        if url.scheme?.lowercased() == "https" { return url }
        guard url.scheme?.lowercased() == "http", Self.isLoopback(host) else {
            throw OptionalLLMProviderError.invalidEndpoint
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

private struct ChatRequest: Codable {
    let model: String
    let messages: [Message]
}

private struct Message: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Codable {
    struct Choice: Codable { let message: Message }
    let choices: [Choice]
}
