import Foundation
import FoundationModels

nonisolated enum AppleCleanupFailure: CleanupError, Equatable {
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unavailable
    case tooLong
    case timedOut
    case changedContent
    case droppedContent
    case generation

    /// `nil` cuando el modelo está listo para usarse.
    init?(availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: self = .deviceNotEligible
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceDisabled
            case .modelNotReady: self = .modelNotReady
            @unknown default: self = .unavailable
            }
        }
    }

    var reason: String {
        switch self {
        case .deviceNotEligible: "este Mac no admite el modelo de Apple"
        case .appleIntelligenceDisabled: "Apple Intelligence está desactivada en Ajustes del Sistema"
        case .modelNotReady: "el modelo de Apple aún se está descargando"
        case .unavailable: "el modelo de Apple no está disponible"
        case .tooLong: "el dictado es demasiado largo para el modelo de Apple"
        case .timedOut: "el modelo de Apple tardó demasiado"
        case .changedContent: "el modelo de Apple cambió palabras del dictado"
        case .droppedContent: "el modelo de Apple quitó parte del dictado"
        case .generation: "el modelo de Apple no pudo procesar el texto"
        }
    }
}

/// Limpieza con el modelo de lenguaje de Apple en el propio Mac (AFM 3 Core en macOS 27, ~4K tokens
/// de contexto). Es experimental: sigue peor las instrucciones que Ollama, así que su salida pasa por
/// `CleanupGuard` y cualquier duda acaba en el texto bruto con aviso, que es el contrato de FluFlu.
@MainActor
final class AppleTranscriptCleaner: TranscriptCleaner {
    private static let log = AppLog(category: "cleanup")
    /// Mismo plazo que Ollama. Sin él, un dictado largo tardaba 40-70 s en fallar y bloqueaba los siguientes.
    static let responseDeadline: Duration = .seconds(25)
    /// Margen para el formato de la sesión y la puntuación que añade la limpieza.
    static let contextMarginTokens = 256
    /// Tope de dictado que el modelo puede reescribir dentro del plazo. Genera unos 50 tokens/s en un
    /// M1 Pro: 1.448 tokens no terminaron en 25 s (2026-10-19). 900 tokens son unos 4 minutos de habla;
    /// lo que pase de ahí se pega sin limpiar al momento en vez de esperar al plazo.
    static let maxTranscriptTokens = 900

    private let model: SystemLanguageModel
    private let localeProvider: @MainActor () -> Locale

    /// `locale` es el idioma del reconocedor: el modelo necesita saberlo para no traducir.
    init(model: SystemLanguageModel = .default, locale: @escaping @MainActor () -> Locale) {
        self.model = model
        self.localeProvider = locale
    }

    /// Nombre en inglés del idioma del dictado («Spanish»), como lo esperan las instrucciones.
    nonisolated static func languageName(of locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? "es"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Texto de estado para Ajustes: qué pasará al dictar con este motor.
    var statusDescription: String {
        AppleCleanupFailure(availability: model.availability).map { "No disponible: \($0.reason)." }
            ?? "Experimental. Funciona en el Mac, sin red ni clave; si duda de su resultado, pega el texto sin limpiar."
    }

    /// Carga el modelo antes del primer dictado: en frío la primera respuesta tardó unos 4 s y en
    /// caliente alrededor de 1 s (M1 Pro, macOS 27.2).
    func prewarm() {
        guard model.isAvailable else { return }
        LanguageModelSession(model: model).prewarm()
    }

    func clean(_ rawTranscript: String, vocabulary: [String]) async throws -> String {
        // Sin palabras no se consulta al modelo: con la entrada vacía se inventaba un texto a partir
        // del vocabulario (prueba del 2026-10-19) y FluFlu lo habría pegado.
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let failure = AppleCleanupFailure(availability: model.availability) { throw failure }
        let prompt = CleanupPrompt.onDevice(rawTranscript: trimmed, vocabulary: vocabulary,
                                            languageName: Self.languageName(of: localeProvider()))
        guard await fitsInBudget(prompt) else { throw AppleCleanupFailure.tooLong }

        // Una sesión por dictado: el historial de uno no debe condicionar la limpieza del siguiente.
        let session = LanguageModelSession(model: model, instructions: prompt.system)
        let content: String
        do {
            content = try await respond(session, to: prompt.user)
        } catch let failure as AppleCleanupFailure {
            throw failure
        } catch {
            // Borde que traduce cualquier fallo del modelo a un resultado estable. Solo se registra el
            // tipo: la descripción de algunos errores podría citar el texto dictado.
            Self.log.warning("apple cleanup failed: \(String(describing: type(of: error)))")
            throw Self.isContextOverflow(error) ? AppleCleanupFailure.tooLong : AppleCleanupFailure.generation
        }

        let cleaned = try OllamaResponseParser.cleanedText(from: content)
        let invented = CleanupGuard.inventedTerms(cleaned: cleaned, raw: trimmed, vocabulary: vocabulary)
        if !invented.isEmpty {
            Self.log.warning("apple cleanup rejected: \(invented.count) term(s) not present in the dictation")
            throw AppleCleanupFailure.changedContent
        }
        if CleanupGuard.lostContent(cleaned: cleaned, raw: trimmed) {
            Self.log.warning("apple cleanup rejected: output dropped part of the dictation")
            throw AppleCleanupFailure.droppedContent
        }
        return cleaned
    }

    /// Dos límites. Contexto: la salida mide casi lo mismo que la entrada, así que el dictado tiene que
    /// caber dos veces junto a las instrucciones (con ~5.000 caracteres el modelo se quedaba sin contexto
    /// a mitad de respuesta, tras más de un minuto). Tiempo: `maxTranscriptTokens`.
    private func fitsInBudget(_ prompt: CleanupPrompt) async -> Bool {
        let instructions: Int
        let transcript: Int
        if #available(macOS 26.4, *),
           let counted = try? await (model.tokenCount(for: prompt.system), model.tokenCount(for: prompt.user)) {
            (instructions, transcript) = counted
        } else {
            // Sin contador exacto (macOS anterior a 26.4), estimación prudente de ~3 caracteres por token.
            (instructions, transcript) = (prompt.system.count / 3, prompt.user.count / 3)
        }
        return transcript <= Self.maxTranscriptTokens
            && instructions + 2 * transcript + Self.contextMarginTokens <= model.contextSize
    }

    /// Respuesta del modelo con plazo. No se usa un grupo de tareas porque, al salir, espera a sus
    /// hijas: si el modelo ignorase la cancelación, el plazo no cortaría nada.
    private func respond(_ session: LanguageModelSession, to prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task {
                do {
                    let response = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy))
                    once.resume(with: .success(response.content))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: Self.responseDeadline)
                if once.resume(with: .failure(AppleCleanupFailure.timedOut)) { work.cancel() }
            }
        }
    }

    private static func isContextOverflow(_ error: any Error) -> Bool {
        if #available(macOS 27, *), let modelError = error as? LanguageModelError, case .contextSizeExceeded = modelError {
            return true
        }
        return false
    }
}

/// Reanuda una continuación una sola vez: la respuesta del modelo y el plazo compiten por ella.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<String, any Error>?

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    /// `true` si esta llamada fue la que reanudó.
    @discardableResult
    func resume(with result: Result<String, any Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}
