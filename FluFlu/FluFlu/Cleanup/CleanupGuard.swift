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

    /// Barrera acotada para Ollama, no una prueba de equivalencia semántica. No aplica la regla
    /// de «cada palabra nueva es inventada»: acepta edición gramatical y vocabulario autorizado.
    /// Protege el valor de las cifras, las negaciones y los literales, no su grafía: la limpieza
    /// existe para escribir «20», «1.000», «iPhone» o «fine-tuning» donde se dictó otra forma, y
    /// rechazarlo pegaba el texto bruto con un aviso de fallo en dictados correctos (2026-11-13).
    static func preservesProtectedContent(cleaned: String, raw: String, vocabulary: [String]) -> Bool {
        if cleaned.isEmpty { return isOnlyFillerSounds(raw) }
        guard numericValues(raw) == numericValues(cleaned) else { return false }
        guard preservesNegations(cleaned: cleaned, raw: raw) else { return false }
        guard preservesLiterals(cleaned: cleaned, raw: raw, vocabulary: vocabulary) else { return false }
        let content = words(raw).filter { !discourseFillers.contains($0) }
        let remaining = words(cleaned).filter { !discourseFillers.contains($0) }
        guard !content.isEmpty else { return true }
        // Cuenta ocurrencias, no solo términos únicos: tampoco permite truncar repeticiones largas.
        return Double(remaining.count) >= minKeptFraction * Double(content.count)
    }

    // MARK: Cifras

    private static let numberPattern = #"(?<![\p{L}\p{N}_])[+-]?\d+(?:[.,:/-]\d+)*(?:[eE][+-]?\d+)?(?:\s?[%‰])?"#
    private static let groupedThousands = #"^[+-]?\d{1,3}(?:[.,]\d{3})+[%‰]?$"#
    /// Numerales de una palabra. Quedan fuera «un/uno/una/one» (artículos) y los compuestos
    /// («treinta y dos»): esos siguen exigiendo la misma grafía, que es la dirección segura.
    private static let spelledNumbers: [String: String] = [
        "cero": "0", "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5", "seis": "6", "siete": "7",
        "ocho": "8", "nueve": "9", "diez": "10", "once": "11", "doce": "12", "trece": "13",
        "catorce": "14", "quince": "15", "veinte": "20", "treinta": "30", "cuarenta": "40",
        "cincuenta": "50", "sesenta": "60", "setenta": "70", "ochenta": "80", "noventa": "90",
        "cien": "100", "mil": "1000",
        "zero": "0", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80",
        "ninety": "90",
    ]

    /// Cifras del texto en orden y en forma canónica, para comparar valor y no formato.
    static func numericValues(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let digits = folded.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let core = word.trimmingCharacters(in: .punctuationCharacters)
            guard let value = spelledNumbers[core] else { return String(word) }
            return word.replacingOccurrences(of: core, with: value)
        }.joined(separator: " ")
        return matches(numberPattern, in: digits).flatMap(canonicalNumber)
    }

    /// «1.000» y «1000» son la misma cifra; «2,5» y «2.5» también; «10:30» equivale a «10 30».
    /// El signo y el exponente se conservan: cambiarlos sí altera el valor.
    private static func canonicalNumber(_ literal: String) -> [String] {
        var number = literal.filter { !$0.isWhitespace }
        if number.range(of: groupedThousands, options: .regularExpression) != nil {
            number.removeAll { $0 == "." || $0 == "," }
            return [number]
        }
        number = number.replacingOccurrences(of: ",", with: ".")
        if number.contains(where: { $0 == "e" || $0 == "E" }) { return [number] }
        let sign = number.first == "+" || number.first == "-" ? String(number.removeFirst()) : ""
        var parts = number.split(whereSeparator: { ":/-".contains($0) }).map(String.init)
        if !parts.isEmpty { parts[0] = sign + parts[0] }
        return parts
    }

    // MARK: Negaciones

    private static let negations: Set<String> = ["no", "not", "never", "neither", "nor", "without", "n't", "nunca", "jamás", "jamas", "ni", "sin", "tampoco", "non", "pas", "nicht", "kein", "sem", "não", "nao", "sans", "rien", "jamais", "aucun", "aucune", "personne", "ohne", "niemals", "keine", "keinen", "keinem", "keiner", "mai", "senza", "niente", "nessuno", "nunca", "nem"]
    /// Un «no» que rectifica («a Juan, no, perdón, a Marta») o que cierra una pregunta («¿no?») no
    /// niega nada: el prompt pide aplicar la rectificación y quitarlo es el resultado esperado.
    private static let correctionMarkers = #"(?i)\bo sea,? no\b|\bno,? (?:perd[oó]n|perdona|mejor|espera|quiero decir|sorry|wait|i mean)\b|¿?\bno\?"#

    private static func negativeWords(_ text: String) -> [String] {
        let expanded = text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "n't", with: " not", options: .caseInsensitive)
            .replacingOccurrences(of: #"\bcannot\b"#, with: "can not", options: [.regularExpression, .caseInsensitive])
        return words(expanded).filter { negations.contains($0) }.sorted()
    }

    private static func preservesNegations(cleaned: String, raw: String) -> Bool {
        let kept = negativeWords(cleaned)
        if kept == negativeWords(raw) { return true }
        let withoutMarkers = raw.replacingOccurrences(of: correctionMarkers, with: " ", options: .regularExpression)
        return withoutMarkers != raw && kept == negativeWords(withoutMarkers)
    }

    // MARK: Literales

    // URLs, rutas, nombres de archivo e identificadores explícitos. La puntuación terminal
    // queda fuera; mayúsculas en prosa siguen siendo libres, dentro de un literal no.
    private static let literalPattern = #"(?i:[a-z][a-z0-9+.-]*://[^\s<>"`]+)|(?:~/|/|\./|\.\./)[^\s<>"`]+|\b[\p{L}_][\p{L}\p{N}_]*_[\p{L}\p{N}_]+\b|\b[\p{L}\p{N}_-]+\.[\p{L}][\p{L}\p{N}]{0,9}\b|\b[a-z]+[A-Z][a-zA-Z0-9]*\b|\b[\p{L}_][\p{L}\p{N}_]*\d[\p{L}\p{N}_]*\b|\b[\p{L}][\p{L}\p{N}]*-[\p{L}\p{N}-]+\b|`[^`]+`"#

    private static func protectedLiterals(_ text: String) -> [String] {
        matches(literalPattern, in: text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}")) }.sorted()
    }

    /// Solo letras y cifras, sin mayúsculas ni acentos: la forma en que se dijo, sin su grafía.
    private static func spoken(_ text: String) -> String {
        words(text).joined()
    }

    private static func preservesLiterals(cleaned: String, raw: String, vocabulary: [String]) -> Bool {
        var result = protectedLiterals(cleaned)
        for literal in protectedLiterals(raw) {
            // Un literal dictado en minúsculas no trae grafía que proteger («m1» → «M1»); uno con
            // mayúsculas propias («userID») debe llegar idéntico.
            let recasable = literal == literal.lowercased()
            guard let index = result.firstIndex(where: { recasable ? $0.lowercased() == literal : $0 == literal }) else { return false }
            result.remove(at: index)
        }
        // Lo que queda son literales nuevos: se admiten los del vocabulario y los que solo reescriben
        // palabras dictadas («iphone» → «iPhone», «fine tuning» → «fine-tuning»).
        let authorized = Set(vocabulary.flatMap { protectedLiterals($0) })
        let dictated = spoken(raw)
        return result.allSatisfy { authorized.contains($0) || dictated.contains(spoken($0)) }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

}
