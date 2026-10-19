import Foundation

/// Comprobaciones deterministas sobre lo que devuelve un modelo de limpieza. Un modelo puede
/// tirar un dictado o cambiarle el sentido sin avisar (con el de Apple se vio «al inglés» → «al
/// español» y «vale» → «VALOR», 2026-10-19); estas reglas no dependen del modelo y, ante la duda,
/// prefieren el texto bruto, que es la dirección segura.
nonisolated enum CleanupGuard {
    /// Sonidos de relleno que justifican devolver vacío. Solo vocalizaciones: «vale» o «bueno»
    /// pueden ser la respuesta entera que se quería dictar.
    static let fillerSounds: Set<String> = ["eh", "ehh", "eeh", "em", "emm", "mm", "mmm", "hm", "hmm", "ah", "uh", "um", "uhm"]

    /// Muletillas que la limpieza quita con razón; no cuentan como contenido perdido.
    static let discourseFillers: Set<String> = fillerSounds.union(["bueno", "pues", "vale", "o", "sea", "este", "like", "you", "know"])
    /// Una rectificación («a Juan, no, perdón, a Marta») quita unas pocas palabras; quitar más que esto,
    /// o quedarse con menos del 60 % de lo dictado, es resumir o tirar una parte («traduce al inglés…»).
    static let maxMissingWords = 3
    static let maxMissingFraction = 0.2
    static let minKeptFraction = 0.6

    /// Palabras y números del texto en orden, sin mayúsculas ni acentos.
    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(words(text))
    }

    static func isOnlyFillerSounds(_ text: String) -> Bool {
        tokens(text).isSubset(of: fillerSounds)
    }

    /// Términos de la salida que no estaban en el dictado ni en el vocabulario. Limpiar solo quita
    /// palabras, corrige puntuación, mayúsculas y acentos, y acerca grafías al vocabulario; una
    /// palabra o cifra nueva significa que el modelo ha reescrito el contenido.
    static func inventedTerms(cleaned: String, raw: String, vocabulary: [String]) -> Set<String> {
        tokens(cleaned)
            .subtracting(tokens(raw))
            .subtracting(vocabulary.flatMap { tokens($0) })
    }

    /// `true` si la limpieza quitó contenido además de muletillas y rectificaciones. Umbrales probados
    /// el 2026-10-19 con salidas reales del modelo de Apple: aceptan las rectificaciones y rechazan una
    /// orden quitada y un resumen. Un falso positivo solo acaba en el texto bruto.
    static func lostContent(cleaned: String, raw: String) -> Bool {
        let rawContent = words(raw).filter { !discourseFillers.contains($0) }
        guard !rawContent.isEmpty else { return false }
        let kept = words(cleaned).filter { !discourseFillers.contains($0) }
        let missing = Set(rawContent).subtracting(kept)
        let missingLimit = max(maxMissingWords, Int(maxMissingFraction * Double(Set(rawContent).count)))
        return missing.count > missingLimit || Double(kept.count) < minKeptFraction * Double(rawContent.count)
    }
}
