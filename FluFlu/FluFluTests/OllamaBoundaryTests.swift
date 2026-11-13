import Foundation
import Synchronization
import Testing
@testable import FluFlu

nonisolated final class OllamaStubProtocol: URLProtocol {
    struct State: Sendable {
        var requests: [URLRequest] = []
        var status = 200
        var content = "Hola."
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, content) = Self.state.withLock {
            $0.requests.append(request)
            return ($0.status, $0.content)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: status == 302 ? ["Location": "https://redirect.invalid/api/chat"] : [:])!
        let data = try! JSONSerialization.data(withJSONObject: ["message": ["content": content]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct OllamaBoundaryTests {
    private func session(status: Int = 200, content: String = "Hola.") -> URLSession {
        OllamaStubProtocol.state.withLock { $0 = .init(status: status, content: content) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaStubProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func canonicalCloudReadsAndSendsKey() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var reads = 0
        let cleaner = OllamaTranscriptCleaner(
            endpoint: { OllamaEndpoint(host: .cloud, baseURL: URL(string: "https://ollama.com:443")!, model: "fake") },
            apiKey: { reads += 1; return " synthetic-key " }, consent: { true }, session: session)
        #expect(try await cleaner.clean("hola", vocabulary: []) == "Hola.")
        #expect(reads == 1)
        #expect(OllamaStubProtocol.state.withLock { $0.requests.first?.value(forHTTPHeaderField: "Authorization") } == "Bearer synthetic-key")
    }

    @Test(arguments: ["http://localhost:11434", "https://custom.invalid", "https://ollama.com"])
    func localOptionNeverReadsOrSendsCloudKey(url: String) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var reads = 0
        let cleaner = OllamaTranscriptCleaner(endpoint: { OllamaEndpoint(host: .local, baseURL: URL(string: url)!, model: "fake") },
                                              apiKey: { reads += 1; return "synthetic-key" }, consent: { true }, session: session)
        _ = try await cleaner.clean("hola", vocabulary: [])
        #expect(reads == 0)
        #expect(OllamaStubProtocol.state.withLock { $0.requests.first?.value(forHTTPHeaderField: "Authorization") } == nil)
    }

    @Test(arguments: ["http://ollama.com", "https://ollama.com:444", "https://ollama.com.evil.invalid",
                      "https://user@ollama.com", "https://ollama.com/path", "https://ollama.com?x=1",
                      "https://ollama.com#fragment", "https://ollama.com.", "https://%6fllama.com"])
    func cloudLabelCannotAuthorizeAnAlternativeURL(url: String) async {
        let session = session()
        defer { session.invalidateAndCancel() }
        var reads = 0
        let cleaner = OllamaTranscriptCleaner(endpoint: { OllamaEndpoint(host: .cloud, baseURL: URL(string: url)!, model: "fake") },
                                              apiKey: { reads += 1; return "synthetic-key" }, consent: { true }, session: session)
        await #expect(throws: OllamaFailure.invalidEndpoint) { try await cleaner.clean("hola", vocabulary: []) }
        #expect(reads == 0)
        #expect(OllamaStubProtocol.state.withLock { $0.requests.isEmpty })
    }

    @Test func consentAndEndpointAreRecheckedOnEveryCall() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let consent = Mutex(false)
        var endpoint = OllamaEndpoint(host: .cloud, baseURL: OllamaEndpoint.cloudBaseURL, model: "fake")
        var reads = 0
        let cleaner = OllamaTranscriptCleaner(endpoint: { endpoint }, apiKey: { reads += 1; return "synthetic-key" },
                                              consent: { consent.withLock { $0 } }, session: session)
        await #expect(throws: OllamaFailure.consentMissing) { try await cleaner.clean("hola", vocabulary: []) }
        #expect(reads == 0)
        #expect(OllamaStubProtocol.state.withLock { $0.requests.isEmpty })
        consent.withLock { $0 = true }
        _ = try await cleaner.clean("hola", vocabulary: [])
        consent.withLock { $0 = false }
        await #expect(throws: OllamaFailure.consentMissing) { try await cleaner.clean("hola", vocabulary: []) }
        endpoint = OllamaEndpoint(host: .local, baseURL: OllamaEndpoint.defaultLocalBaseURL, model: "fake")
        _ = try await cleaner.clean("hola", vocabulary: [])
        #expect(reads == 1)
        #expect(OllamaStubProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test func redirectResponseIsActionableAndNoFollowupIsSent() async {
        let session = session(status: 302)
        defer { session.invalidateAndCancel() }
        let cleaner = OllamaTranscriptCleaner(endpoint: { OllamaEndpoint(host: .local, baseURL: OllamaEndpoint.defaultLocalBaseURL, model: "fake") },
                                              apiKey: { Issue.record("Local accessed key"); return nil }, consent: { false }, session: session)
        await #expect(throws: OllamaFailure.redirect) { try await cleaner.clean("hola", vocabulary: []) }
        #expect(OllamaStubProtocol.state.withLock { $0.requests.count } == 1)
    }

    @Test(arguments: ["https://different.invalid/api/chat", "http://ollama.com/api/chat", "https://ollama.com/other"])
    func redirectDelegateRefusesEveryDestination(url: String) async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://ollama.com/api/chat")!
        let result = await withCheckedContinuation { continuation in
            RejectOllamaRedirects().urlSession(session, task: session.dataTask(with: original),
                willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: URL(string: url)!)) { continuation.resume(returning: $0) }
        }
        #expect(result == nil)
        #expect(OllamaStubProtocol.state.withLock { $0.requests.isEmpty })
    }

    @Test func unsafeModelOutputIsRejectedAtClientBoundary() async {
        let session = session(content: "Hay 13 tareas.")
        defer { session.invalidateAndCancel() }
        let cleaner = OllamaTranscriptCleaner(endpoint: { OllamaEndpoint(host: .local, baseURL: OllamaEndpoint.defaultLocalBaseURL, model: "fake") },
                                              apiKey: { nil }, consent: { false }, session: session)
        await #expect(throws: OllamaFailure.changedContent) { try await cleaner.clean("hay 12 tareas", vocabulary: []) }
    }
}
