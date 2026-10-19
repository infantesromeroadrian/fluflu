import Foundation
import Testing
@testable import FluFlu

struct OllamaResponseParserTests {
    @Test func trimsSurroundingWhitespace() throws {
        #expect(try OllamaResponseParser.cleanedText(from: "  Hola, mundo. \n") == "Hola, mundo.")
    }

    @Test func stripsWrappingQuotes() throws {
        #expect(try OllamaResponseParser.cleanedText(from: "\"Hola, mundo.\"") == "Hola, mundo.")
        #expect(try OllamaResponseParser.cleanedText(from: "“Hola, mundo.”") == "Hola, mundo.")
        #expect(try OllamaResponseParser.cleanedText(from: "«Hola, mundo.»") == "Hola, mundo.")
    }

    @Test func keepsInnerQuotesUntouched() throws {
        #expect(try OllamaResponseParser.cleanedText(from: "Dijo \"hola\" y se fue.") == "Dijo \"hola\" y se fue.")
    }

    @Test func emptySentinelBecomesEmptyText() throws {
        #expect(try OllamaResponseParser.cleanedText(from: " EMPTY ") == "")
    }

    @Test func blankContentIsAnError() {
        #expect(throws: OllamaFailure.emptyResponse) { try OllamaResponseParser.cleanedText(from: "   \n") }
    }
}

struct OllamaChatRequestTests {
    @Test func cleanupRequestFixesStreamingAndThinkingOff() throws {
        let prompt = CleanupPrompt.make(rawTranscript: "hola", vocabulary: [])
        let request = OllamaChatRequest.cleanup(model: "gemma4:31b", prompt: prompt)
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "gemma4:31b")
        #expect(json["stream"] as? Bool == false)
        #expect(json["think"] as? Bool == false)
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    }
}

struct OllamaEndpointTests {
    @Test func cloudEndpointRequiresKeyAndTargetsOllamaCom() {
        let endpoint = OllamaEndpoint(host: .cloud, baseURL: OllamaEndpoint.cloudBaseURL, model: "m")
        #expect(endpoint.requiresAPIKey)
        #expect(endpoint.chatURL.absoluteString == "https://ollama.com/api/chat")
    }

    @Test func localEndpointDoesNotRequireKey() {
        let endpoint = OllamaEndpoint(host: .local, baseURL: OllamaEndpoint.defaultLocalBaseURL, model: "m")
        #expect(!endpoint.requiresAPIKey)
        #expect(endpoint.chatURL.absoluteString == "http://localhost:11434/api/chat")
    }
}

@MainActor
struct AppSettingsTests {
    private func freshSettings() -> AppSettings {
        let suite = "FluFluTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    @Test func defaultsPointToSpanishCloudCleanup() {
        let settings = freshSettings()
        #expect(settings.localeIdentifier == "es-ES")
        #expect(settings.shortcuts == [.dictate: .rightOption])
        #expect(settings.cleanupEnabled)
        #expect(settings.ollamaEndpoint?.host == .cloud)
    }

    @Test func invalidLocalURLYieldsNoEndpoint() {
        let settings = freshSettings()
        settings.ollamaHost = .local
        settings.ollamaLocalURL = "localhost sin esquema"
        #expect(settings.ollamaEndpoint == nil)
        settings.ollamaLocalURL = "http://127.0.0.1:11434"
        #expect(settings.ollamaEndpoint?.chatURL.absoluteString == "http://127.0.0.1:11434/api/chat")
    }

    @Test func vocabularyIgnoresBlankLinesAndTrimsTerms() {
        let settings = freshSettings()
        settings.vocabulary = "  Anthropic \n\n Verisure\n"
        #expect(settings.vocabularyTerms == ["Anthropic", "Verisure"])
    }
}
