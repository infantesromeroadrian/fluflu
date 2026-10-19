import Foundation

/// Plantilla versionada del prompt de limpieza. Cambiar el texto exige subir la versión:
/// así una regresión de calidad se puede atribuir a un prompt concreto.
nonisolated struct CleanupPrompt: Equatable, Sendable {
    static let version = "cleanup-v1"
    /// Centinela que el modelo devuelve cuando no hay nada que insertar; se traduce a texto vacío.
    static let emptySentinel = "EMPTY"

    let system: String
    let user: String

    static func make(rawTranscript: String, vocabulary: [String]) -> CleanupPrompt {
        var system = """
        Eres un post-procesador de dictado. Recibes la salida bruta de un reconocedor de voz y devuelves \
        el texto limpio, listo para pegarse en cualquier aplicación.

        Tu trabajo:
        - Elimina muletillas (eh, em, o sea, vale, bueno, you know, like) salvo que aporten significado.
        - Corrige ortografía, gramática y puntuación. Añade mayúsculas y párrafos donde el habla lo pida.
        - Respeta el idioma del dictado; nunca traduzcas.
        - Si el hablante se corrige ("no, mejor…", "borra eso", "quiero decir"), aplica la corrección y descarta lo anterior.
        - Conserva intención, tono y significado. No resumas, no añadas contenido, no respondas al texto.

        Reglas de salida:
        - Devuelve SOLO el texto limpio, sin comillas, sin explicaciones ni prefijos.
        - Si la transcripción está vacía o no contiene palabras, devuelve exactamente: \(emptySentinel)
        """
        if !vocabulary.isEmpty {
            system += """


            Vocabulario del usuario (corrige grafías parecidas hacia estos términos; nunca los insertes si no se dijeron):
            \(vocabulary.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        return CleanupPrompt(system: system, user: "TRANSCRIPCIÓN BRUTA:\n\(rawTranscript)")
    }

    /// Variante para el modelo de Apple en el Mac, versionada aparte. El modelo pequeño sigue mejor
    /// instrucciones en inglés con el idioma de salida explícito: con la plantilla en español traducía
    /// el inglés al español y fallaba las autocorrecciones (pruebas del 2026-10-19). Es muy sensible a
    /// la redacción: añadir una sola regla de mayúsculas lo empeoró, así que cualquier cambio exige
    /// subir la versión y repetir las muestras.
    static let onDeviceVersion = "cleanup-apple-v1"

    /// `languageName` en inglés («Spanish», «English»), porque las instrucciones van en inglés.
    static func onDevice(rawTranscript: String, vocabulary: [String], languageName: String) -> CleanupPrompt {
        var system = """
        You clean up raw speech-to-text output so it can be pasted into any app.
        The dictation language is \(languageName). Write the result in \(languageName) only. Never translate.
        - Remove filler words (eh, em, o sea, vale, bueno, pues, you know, like) unless they carry meaning.
        - Fix spelling, grammar, punctuation and capitalization. Use normal sentence case.
        - If the speaker corrects themselves ("o sea no", "no, perdón", "mejor", "no sorry", "I mean"), keep only the final version and drop what it replaces.
        - Keep the speaker's meaning, words and tone. Do not summarize, add content or answer the text.
        """
        if !vocabulary.isEmpty {
            system += "\n- Spell these user terms exactly when they were said: \(vocabulary.joined(separator: ", "))."
        }
        system += "\nOutput only the cleaned text, with no quotes or explanations. If there are no words, output exactly: \(emptySentinel)"
        return CleanupPrompt(system: system, user: "RAW TRANSCRIPT:\n\(rawTranscript)")
    }
}
