import Foundation

/// Qué modelo pule el dictado. Apple corre en el propio Mac (FoundationModels: sin red, sin clave y
/// el texto no sale del equipo); Ollama, en su servidor Cloud o local según `OllamaHost`.
nonisolated enum CleanupEngine: String, CaseIterable, Codable, Sendable {
    case apple
    case ollama

    /// Motores que se ofrecen en Ajustes. Apple queda fuera tras la prueba real del 2026-10-19 (limpiaba
    /// peor y gastaba cómputo del Mac); su código se conserva para Private Cloud Compute.
    static let offered: [CleanupEngine] = [.ollama]

    var title: String {
        switch self {
        case .apple: "Apple (en el Mac)"
        case .ollama: "Ollama"
        }
    }
}
