import Foundation

/// Resultado de una sesión de dictado: lo confirmado por el motor, ya unido en un solo texto.
nonisolated struct TranscriptionOutcome: Equatable, Sendable {
    let text: String
}

/// Contrato del motor de voz. Apple es el único hoy; WhisperKit o Parakeet encajarían aquí sin tocar el controlador.
@MainActor
protocol SpeechEngine: AnyObject {
    /// Comprueba disponibilidad y descarga el modelo del idioma si falta. Idempotente.
    func prepare(locale: Locale) async throws
    /// Consume el audio hasta que el ingress termine y devuelve el texto final.
    func transcribe(_ ingress: AudioIngress, locale: Locale, onPartial: @escaping @MainActor (String) -> Void) async throws -> TranscriptionOutcome
}
