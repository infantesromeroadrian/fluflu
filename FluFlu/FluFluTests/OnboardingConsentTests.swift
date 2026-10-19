import Foundation
import Synchronization
import Testing
@testable import FluFlu

@MainActor
struct OnboardingSettingsTests {
    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "FluFluTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    /// Una instalación nueva ve la bienvenida y no envía nada a Ollama Cloud hasta que se acepta.
    @Test func newInstallNeedsOnboardingAndConsent() {
        withFreshDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(!settings.onboardingCompleted)
            #expect(!settings.cloudConsent)
        }
    }

    @Test func onboardingAndConsentPersist() {
        withFreshDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.onboardingCompleted = true
            settings.cloudConsent = true
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.onboardingCompleted)
            #expect(reloaded.cloudConsent)
        }
    }

    @Test func cloudAsksForConsent() {
        #expect(OllamaEndpoint(host: .cloud, baseURL: OllamaEndpoint.cloudBaseURL, model: "m").requiresConsent)
    }

    @Test(arguments: ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434", "http://LOCALHOST:11434"])
    func anOllamaOnThisMacNeedsNoConsent(url: String) {
        #expect(!OllamaEndpoint(host: .local, baseURL: URL(string: url)!, model: "m").requiresConsent)
    }

    /// La opción «local» acepta cualquier URL: si apunta fuera del Mac, el texto sale y hay que consentirlo.
    @Test(arguments: ["https://ollama.com", "http://192.168.1.20:11434", "https://ollama.example.org"])
    func aLocalOptionPointingElsewhereNeedsConsent(url: String) {
        #expect(OllamaEndpoint(host: .local, baseURL: URL(string: url)!, model: "m").requiresConsent)
    }
}

/// Registra cada petición que intenta salir por la sesión de la prueba y la corta sin tocar la red.
nonisolated final class RecordingURLProtocol: URLProtocol {
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// En serie: las dos pruebas comparten el contador de `RecordingURLProtocol`.
@MainActor
@Suite(.serialized)
struct OllamaConsentGateTests {
    private func cleaner(consent: Bool) -> OllamaTranscriptCleaner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return OllamaTranscriptCleaner(
            endpoint: { OllamaEndpoint(host: .cloud, baseURL: OllamaEndpoint.cloudBaseURL, model: "gemma4:31b") },
            apiKey: { "clave-de-prueba" },
            consent: { consent },
            session: URLSession(configuration: configuration)
        )
    }

    @Test func withoutConsentNothingLeavesTheMac() async {
        let before = RecordingURLProtocol.requests.withLock { $0 }
        await #expect(throws: OllamaFailure.consentMissing) {
            try await cleaner(consent: false).clean("hola qué tal", vocabulary: [])
        }
        #expect(RecordingURLProtocol.requests.withLock { $0 } == before)
    }

    /// Control positivo: con consentimiento la petición sí sale, así que el contador mide de verdad.
    @Test func withConsentTheRequestIsSent() async {
        let before = RecordingURLProtocol.requests.withLock { $0 }
        await #expect(throws: OllamaFailure.transport) {
            try await cleaner(consent: true).clean("hola qué tal", vocabulary: [])
        }
        #expect(RecordingURLProtocol.requests.withLock { $0 } == before + 1)
    }
}

/// Cada variante compila con sus permisos: la tienda (sandbox) no puede consumir la tecla.
@MainActor
struct KeyboardAccessVariantTests {
    #if APP_STORE
    @Test func storeVariantListensWithoutReservingTheKey() {
        #expect(!KeyboardAccess.reservesKey)
        #expect(KeyboardAccess.title == "Teclado")
    }
    #else
    @Test func directVariantUsesAccessibilityAndReservesTheKey() {
        #expect(KeyboardAccess.reservesKey)
        #expect(KeyboardAccess.title == "Accesibilidad")
    }
    #endif
}
