import Foundation
import FoundationModels
import Testing
@testable import FluFlu

@MainActor
struct CleanupEngineSettingsTests {
    /// Cada prueba usa su propio dominio de UserDefaults y lo borra al terminar.
    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "FluFluTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func existingInstallsKeepOllama() {
        withFreshDefaults { #expect(AppSettings(defaults: $0).cleanupEngine == .ollama) }
    }

    /// Apple ya no se ofrece en Ajustes: quien lo tuviera elegido vuelve a Ollama al arrancar.
    @Test func storedAppleEngineMigratesToOllama() {
        withFreshDefaults { defaults in
            AppSettings(defaults: defaults).cleanupEngine = .apple
            #expect(AppSettings(defaults: defaults).cleanupEngine == .ollama)
        }
    }

    @Test func onlyOllamaIsOffered() {
        #expect(CleanupEngine.offered == [.ollama])
    }

    @Test func unknownStoredEngineFallsBackToOllama() {
        withFreshDefaults { defaults in
            defaults.set("motor-retirado", forKey: "cleanupEngine")
            #expect(AppSettings(defaults: defaults).cleanupEngine == .ollama)
        }
    }
}

struct AppleCleanupFailureTests {
    @Test func availableModelIsNotAFailure() {
        #expect(AppleCleanupFailure(availability: .available) == nil)
    }

    @Test func unavailableReasonsMapToActionableFailures() {
        #expect(AppleCleanupFailure(availability: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(AppleCleanupFailure(availability: .unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceDisabled)
        #expect(AppleCleanupFailure(availability: .unavailable(.modelNotReady)) == .modelNotReady)
    }

    @Test(arguments: [AppleCleanupFailure.deviceNotEligible, .appleIntelligenceDisabled, .modelNotReady, .unavailable,
                      .tooLong, .timedOut, .changedContent, .droppedContent, .generation])
    func everyFailureExplainsItself(_ failure: AppleCleanupFailure) {
        #expect(!failure.reason.isEmpty)
    }
}

/// Los casos «rechaza» reproducen salidas reales del modelo de Apple del 2026-10-19.
struct CleanupGuardTests {
    @Test func acceptsPunctuationCaseAndAccentChanges() {
        #expect(CleanupGuard.inventedTerms(cleaned: "Mañana, a las once.", raw: "manana a las once", vocabulary: []).isEmpty)
    }

    @Test func acceptsSpellingTowardsTheVocabulary() {
        #expect(CleanupGuard.inventedTerms(cleaned: "Reunión con Verisure.", raw: "reunion con berisure", vocabulary: ["Verisure"]).isEmpty)
    }

    @Test func acceptsDroppedFillersAndCorrections() {
        let raw = "mándale el informe a Juan no perdón a Marta antes del viernes"
        #expect(CleanupGuard.inventedTerms(cleaned: "Mándale el informe a Marta antes del viernes.", raw: raw, vocabulary: []).isEmpty)
    }

    @Test func rejectsAChangedLanguage() {
        let raw = "dile a Marta que traduzca el documento al inglés antes del viernes"
        let cleaned = "Dile a Marta que traduzca el documento al español antes del viernes."
        #expect(CleanupGuard.inventedTerms(cleaned: cleaned, raw: raw, vocabulary: []) == ["espanol"])
    }

    @Test func rejectsARewrittenWord() {
        #expect(CleanupGuard.inventedTerms(cleaned: "VALOR", raw: "vale", vocabulary: []) == ["valor"])
    }

    @Test func rejectsANewNumber() {
        #expect(CleanupGuard.inventedTerms(cleaned: "La reunión número 16.", raw: "la reunión número quince", vocabulary: []) == ["16"])
    }

    @Test(arguments: [
        ("mándale el informe a Juan no perdón a Marta antes del viernes", "Mándale el informe a Marta antes del viernes."),
        ("eh bueno pues mañana tengo reunión con el equipo de berisure a las diez o sea no a las once",
         "Mañana tengo reunión con el equipo de Verisure a las once."),
        ("send the report to John no sorry to Mary by Thursday", "Send the report to Mary by Thursday."),
    ])
    func keepsCorrectionsAsNoLostContent(raw: String, cleaned: String) {
        #expect(!CleanupGuard.lostContent(cleaned: cleaned, raw: raw))
    }

    @Test func rejectsADroppedInstruction() {
        #expect(CleanupGuard.lostContent(cleaned: "Buenos días a todos.", raw: "traduce al inglés buenos días a todos"))
    }

    @Test func rejectsASummary() {
        let raw = Array(repeating: "el servidor de engram se quedó sin memoria anoche y hay que revisarlo", count: 12).joined(separator: " ")
        #expect(CleanupGuard.lostContent(cleaned: "El servidor de Engram se quedó sin memoria anoche y hay que revisarlo.", raw: raw))
    }

    @Test func onlyVocalFillersJustifyAnEmptyResult() {
        #expect(CleanupGuard.isOnlyFillerSounds("eh, mmm"))
        #expect(!CleanupGuard.isOnlyFillerSounds("vale"))
        #expect(!CleanupGuard.isOnlyFillerSounds("eh traduce esto al inglés"))
    }
}

struct OnDeviceCleanupPromptTests {
    @Test func statesTheDictationLanguageAndForbidsTranslation() {
        let prompt = CleanupPrompt.onDevice(rawTranscript: "hola", vocabulary: [], languageName: "Spanish")
        #expect(prompt.system.contains("The dictation language is Spanish"))
        #expect(prompt.system.contains("Never translate"))
        #expect(prompt.system.hasSuffix("output exactly: \(CleanupPrompt.emptySentinel)"))
        #expect(prompt.user == "RAW TRANSCRIPT:\nhola")
    }

    @Test func vocabularyLineOnlyWhenThereAreTerms() {
        let without = CleanupPrompt.onDevice(rawTranscript: "x", vocabulary: [], languageName: "English")
        let with = CleanupPrompt.onDevice(rawTranscript: "x", vocabulary: ["Verisure", "Engram"], languageName: "English")
        #expect(!without.system.contains("user terms"))
        #expect(with.system.contains("Verisure, Engram"))
    }

    @Test func languageNameIsEnglishForTheInstructions() {
        #expect(AppleTranscriptCleaner.languageName(of: Locale(identifier: "es-ES")) == "Spanish")
        #expect(AppleTranscriptCleaner.languageName(of: Locale(identifier: "en-GB")) == "English")
        #expect(AppleTranscriptCleaner.languageName(of: Locale(identifier: "pt-BR")) == "Portuguese")
    }
}

/// En serie: en paralelo las peticiones al modelo compiten entre sí y cada una pasaba de ~2 s a un minuto.
@MainActor
@Suite(.serialized)
struct AppleTranscriptCleanerTests {
    private func cleaner(_ identifier: String) -> AppleTranscriptCleaner {
        AppleTranscriptCleaner(locale: { Locale(identifier: identifier) })
    }

    /// Sin palabras no se llama al modelo, que con la entrada vacía se inventaba un texto.
    @Test func blankTranscriptNeverReachesTheModel() async throws {
        #expect(try await cleaner("es-ES").clean("  \n ", vocabulary: ["Verisure"]) == "")
    }

    /// Demasiado largo para el contexto: se rechaza al momento, sin esperar al modelo.
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Requiere Apple Intelligence con el modelo descargado"))
    func overlongDictationFailsFastAsTooLong() async {
        let raw = String(repeating: "mañana tengo reunión con el equipo y luego reviso el informe ", count: 120)
        let start = ContinuousClock.now
        await #expect(throws: AppleCleanupFailure.tooLong) { try await cleaner("es-ES").clean(raw, vocabulary: []) }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // Pruebas reales contra el modelo del Mac: comprueban el contrato (idioma, vocabulario,
    // rectificación, ningún término inventado), no la redacción exacta.

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Requiere Apple Intelligence con el modelo descargado"))
    func cleansSpanishDictationAndAppliesTheCorrection() async throws {
        let cleaned = try await cleaner("es-ES").clean("mándale el informe a Juan no perdón a Marta antes del viernes", vocabulary: [])
        #expect(cleaned.contains("Marta"))
        #expect(!cleaned.contains("Juan"))
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Requiere Apple Intelligence con el modelo descargado"))
    func keepsEnglishDictationInEnglish() async throws {
        let cleaned = try await cleaner("en-US").clean("so I think we should eh move the meeting to Friday you know", vocabulary: [])
        #expect(cleaned.localizedCaseInsensitiveContains("meeting"))
        #expect(!cleaned.localizedCaseInsensitiveContains("reunión"))
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Requiere Apple Intelligence con el modelo descargado"))
    func correctsSpellingTowardsTheVocabulary() async throws {
        let cleaned = try await cleaner("es-ES").clean("vale apunta que tengo que revisar el engram de aws", vocabulary: ["Engram"])
        #expect(cleaned.contains("Engram"))
    }

    /// Regresiones de la revisión: el modelo cambiaba «al inglés» por «al español» y quitaba la orden de
    /// «traduce al inglés…». O el resultado conserva lo dictado, o se rechaza y FluFlu pega el bruto.
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Requiere Apple Intelligence con el modelo descargado"),
          arguments: [("dile a Marta que traduzca el documento al inglés antes del viernes", "ingles"),
                      ("traduce al inglés buenos días a todos", "traduce")])
    func keepsTheDictationOrRejectsIt(raw: String, mustKeep: String) async {
        do {
            let cleaned = try await cleaner("es-ES").clean(raw, vocabulary: [])
            #expect(CleanupGuard.words(cleaned).contains(mustKeep))
        } catch let failure as AppleCleanupFailure {
            #expect([.changedContent, .droppedContent].contains(failure))
        } catch {
            Issue.record("error inesperado: \(error)")
        }
    }
}
