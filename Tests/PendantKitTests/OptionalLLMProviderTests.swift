import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PendantKit
import Domain

final class OptionalLLMProviderTests: XCTestCase {
    func testLoopbackProviderSendsTextOnlyOpenAICompatibleRequest() async throws {
        let transport = MockLLMTransport(
            response: Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Summary\"}}]}".utf8)
        )
        let provider = OptionalLLMProvider(transport: transport)
        let result = try await provider.generate(
            LLMGenerationRequest(transcript: "Transcript text", instruction: "Summarize"),
            configuration: OptionalLLMConfiguration(endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!, model: "local-model")
        )
        XCTAssertEqual(result.text, "Summary")
        XCTAssertFalse(result.processedRemotely)
        let recordedRequest = await transport.request
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("Transcript text"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("audio"))
    }

    func testRejectsInsecureRemoteAndLimitlessHosts() async {
        let provider = OptionalLLMProvider(transport: MockLLMTransport(response: Data()))
        let request = LLMGenerationRequest(transcript: "text", instruction: "summary")
        await XCTAssertThrowsErrorAsync(try await provider.generate(request, configuration: OptionalLLMConfiguration(endpoint: URL(string: "http://example.com/v1/chat/completions")!, model: "m"))) {
            XCTAssertEqual($0 as? OptionalLLMProviderError, .invalidEndpoint)
        }
        await XCTAssertThrowsErrorAsync(try await provider.generate(request, configuration: OptionalLLMConfiguration(endpoint: URL(string: "https://api.limitless.ai/v1/chat/completions")!, model: "m"))) {
            XCTAssertEqual($0 as? OptionalLLMProviderError, .prohibitedEndpoint)
        }
    }

    func testReportsHTTPAndMalformedResponses() async {
        let request = LLMGenerationRequest(transcript: "text", instruction: "summary")
        let endpoint = URL(string: "https://provider.example/v1/chat/completions")!
        let badHTTP = OptionalLLMProvider(transport: MockLLMTransport(response: Data(), status: 429))
        await XCTAssertThrowsErrorAsync(try await badHTTP.generate(request, configuration: OptionalLLMConfiguration(endpoint: endpoint, model: "m"))) {
            XCTAssertEqual($0 as? OptionalLLMProviderError, .httpFailure(429))
        }
        let malformed = OptionalLLMProvider(transport: MockLLMTransport(response: Data("{}".utf8)))
        await XCTAssertThrowsErrorAsync(try await malformed.generate(request, configuration: OptionalLLMConfiguration(endpoint: endpoint, model: "m"))) {
            XCTAssertEqual($0 as? OptionalLLMProviderError, .malformedResponse)
        }
    }
}

private actor MockLLMTransport: OptionalLLMTransport {
    private(set) var request: URLRequest?
    let response: Data
    let status: Int

    init(response: Data, status: Int = 200) { self.response = response; self.status = status }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (response, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { handler(error) }
}
