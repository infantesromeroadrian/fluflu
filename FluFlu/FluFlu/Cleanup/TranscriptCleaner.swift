import Foundation

/// Fallo de limpieza con un motivo legible para la HUD. Lo lanza cualquier motor y el controlador
/// siempre lo resuelve igual: pega el texto bruto y avisa.
nonisolated protocol CleanupError: Error, Sendable {
    var reason: String { get }
}

/// Paso de limpieza. Devuelve texto vacío cuando el modelo decide que no hay nada que pegar.
@MainActor
protocol TranscriptCleaner: AnyObject {
    func clean(_ rawTranscript: String, vocabulary: [String]) async throws -> String
}

/// Sin limpieza: el texto bruto pasa tal cual. Útil cuando el usuario desactiva Ollama.
@MainActor
final class PassthroughCleaner: TranscriptCleaner {
    func clean(_ rawTranscript: String, vocabulary: [String]) async throws -> String {
        rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
