import Foundation

nonisolated enum OllamaFailure: CleanupError, Equatable {
    case missingAPIKey
    case consentMissing
    case invalidEndpoint
    case httpStatus(Int)
    case invalidResponse
    case emptyResponse
    case transport

    var reason: String {
        switch self {
        case .missingAPIKey: "falta la clave de Ollama Cloud (Ajustes)"
        case .consentMissing: "no has aceptado enviar el texto a Ollama Cloud (Ajustes)"
        case .invalidEndpoint: "la URL del servidor no es válida"
        case .httpStatus(let code): "el servidor respondió HTTP \(code)"
        case .invalidResponse: "respuesta con formato inesperado"
        case .emptyResponse: "el modelo devolvió una respuesta vacía"
        case .transport: "sin conexión con el servidor"
        }
    }
}

/// Cuerpo de `/api/chat`. `stream` y `think` fijos: la limpieza quiere una sola respuesta sin razonamiento visible.
nonisolated struct OllamaChatRequest: Encodable, Equatable, Sendable {
    struct Message: Encodable, Equatable, Sendable {
        let role: String
        let content: String
    }
    struct Options: Encodable, Equatable, Sendable {
        let temperature: Double
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let think: Bool
    let options: Options

    static func cleanup(model: String, prompt: CleanupPrompt) -> OllamaChatRequest {
        OllamaChatRequest(
            model: model,
            messages: [Message(role: "system", content: prompt.system), Message(role: "user", content: prompt.user)],
            stream: false,
            think: false,
            options: Options(temperature: 0)
        )
    }
}

nonisolated struct OllamaChatResponse: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let content: String
    }
    let message: Message
}

/// Interpreta la salida del modelo según el contrato del prompt: sin comillas envolventes y con centinela de vacío.
/// Lo comparten Ollama y Apple, porque los dos reciben el mismo `CleanupPrompt`.
nonisolated enum OllamaResponseParser {
    static func cleanedText(from content: String) throws -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OllamaFailure.emptyResponse }
        if text == CleanupPrompt.emptySentinel { return "" }
        let wrappers: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]
        for (open, close) in wrappers where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

/// Cliente mínimo de la API de chat de Ollama, válido para ollama.com y para un servidor local.
@MainActor
final class OllamaTranscriptCleaner: TranscriptCleaner {
    static let requestTimeout: TimeInterval = 25

    private let endpointProvider: @MainActor () -> OllamaEndpoint?
    private let apiKeyProvider: @MainActor () -> String?
    private let consentProvider: @MainActor () -> Bool
    private let session: URLSession

    init(endpoint: @escaping @MainActor () -> OllamaEndpoint?, apiKey: @escaping @MainActor () -> String?,
         consent: @escaping @MainActor () -> Bool, session: URLSession = .shared) {
        self.endpointProvider = endpoint
        self.apiKeyProvider = apiKey
        self.consentProvider = consent
        self.session = session
    }

    func clean(_ rawTranscript: String, vocabulary: [String]) async throws -> String {
        guard let endpoint = endpointProvider() else { throw OllamaFailure.invalidEndpoint }
        if endpoint.requiresConsent && !consentProvider() { throw OllamaFailure.consentMissing }
        let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if endpoint.requiresAPIKey && apiKey.isEmpty { throw OllamaFailure.missingAPIKey }

        let prompt = CleanupPrompt.make(rawTranscript: rawTranscript, vocabulary: vocabulary)
        var request = URLRequest(url: endpoint.chatURL, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(OllamaChatRequest.cleanup(model: endpoint.model, prompt: prompt))

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw OllamaFailure.transport }
        guard let http = response as? HTTPURLResponse else { throw OllamaFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OllamaFailure.httpStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else { throw OllamaFailure.invalidResponse }
        return try OllamaResponseParser.cleanedText(from: decoded.message.content)
    }
}
