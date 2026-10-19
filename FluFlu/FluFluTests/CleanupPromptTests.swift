import Testing
@testable import FluFlu

struct CleanupPromptTests {
    @Test func userMessageCarriesTheRawTranscriptVerbatim() {
        let raw = "eh bueno quería decir que   mañana no voy"
        let prompt = CleanupPrompt.make(rawTranscript: raw, vocabulary: [])
        #expect(prompt.user.hasSuffix(raw))
    }

    @Test func vocabularySectionIsOmittedWhenEmpty() {
        let prompt = CleanupPrompt.make(rawTranscript: "x", vocabulary: [])
        #expect(!prompt.system.contains("Vocabulario del usuario"))
    }

    @Test func vocabularyTermsAreListedOnePerLine() {
        let prompt = CleanupPrompt.make(rawTranscript: "x", vocabulary: ["Anthropic", "Verisure"])
        #expect(prompt.system.contains("- Anthropic\n- Verisure"))
    }

    @Test func systemPromptDeclaresTheEmptySentinel() {
        let prompt = CleanupPrompt.make(rawTranscript: "x", vocabulary: [])
        #expect(prompt.system.contains(CleanupPrompt.emptySentinel))
    }

    @Test func promptIsDeterministic() {
        let a = CleanupPrompt.make(rawTranscript: "hola", vocabulary: ["A"])
        let b = CleanupPrompt.make(rawTranscript: "hola", vocabulary: ["A"])
        #expect(a == b)
    }
}
