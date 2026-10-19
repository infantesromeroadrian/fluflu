import Foundation

/// Dónde vive el modelo de limpieza. Cloud exige clave; local no.
nonisolated enum OllamaHost: String, CaseIterable, Codable, Sendable {
    case cloud
    case local

    var title: String {
        switch self {
        case .cloud: "Ollama Cloud"
        case .local: "Ollama local"
        }
    }
}

nonisolated struct OllamaEndpoint: Equatable, Sendable {
    static let cloudBaseURL = URL(string: "https://ollama.com")!
    static let defaultLocalBaseURL = URL(string: "http://localhost:11434")!
    static let apiKeysURL = URL(string: "https://ollama.com/settings/keys")!
    static let privacyPolicyURL = URL(string: "https://ollama.com/privacy")!

    let host: OllamaHost
    let baseURL: URL
    let model: String

    var chatURL: URL { baseURL.appending(path: "api/chat") }
    var requiresAPIKey: Bool { host == .cloud }
    /// El texto sale del Mac salvo hacia un Ollama en este mismo equipo. La URL «local» admite
    /// cualquier dirección, así que se mira el host y no la opción elegida.
    var requiresConsent: Bool { !Self.loopbackHosts.contains(baseURL.host()?.lowercased() ?? "") }
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
}
