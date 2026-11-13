import AppKit
import Foundation

nonisolated struct InsertionTarget: Equatable, Sendable {
    let processID: Int32
    let launchDate: Date?
    let bundleIdentifier: String?

    init(processID: Int32, launchDate: Date?, bundleIdentifier: String? = nil) {
        self.processID = processID
        self.launchDate = launchDate
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Bordes del ciclo que requieren sistema: permiten probar carreras, cancelación y entrega
/// sin abrir micrófono, escribir portapapeles, consultar llavero ni instalar atajos.
@MainActor
struct DictationEffects {
    var canPost: @MainActor () -> Bool
    var target: @MainActor () -> InsertionTarget?
    var requestMicrophone: @MainActor () async -> Bool
    var prepare: @MainActor (Locale) async throws -> Void
    var startCapture: @MainActor (String) throws -> Void
    var stopCapture: @MainActor () -> Void
    var transcribe: @MainActor (Locale, @escaping @MainActor (String) -> Void) async throws -> String
    var clean: @MainActor (String, [String]) async throws -> String
    var insert: @MainActor (String, InsertionTarget) async throws -> Void
    var prewarm: @MainActor (String) -> Void
    var beginMute: @MainActor (Bool) -> Void
    var endMute: @MainActor () -> Bool

    static func live(settings: AppSettings, engine: any SpeechEngine, inserter: TextInserter,
                     appleCleaner: AppleTranscriptCleaner) -> DictationEffects {
        let recorder = MicrophoneRecorder()
        let mute = OutputMuteSession(device: CoreAudioOutputMute())
        return DictationEffects(
            canPost: { KeyboardAccess.canPost },
            target: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.launchDate != nil else { return nil }
                return InsertionTarget(processID: app.processIdentifier, launchDate: app.launchDate, bundleIdentifier: app.bundleIdentifier)
            },
            requestMicrophone: { await MicrophoneRecorder.requestPermission() },
            prepare: { try await engine.prepare(locale: $0) },
            startCapture: { try recorder.start(deviceUID: $0) },
            stopCapture: { recorder.stop() },
            transcribe: { locale, partial in
                try await engine.transcribe(recorder.ingress, locale: locale, onPartial: partial).text
            },
            clean: { raw, vocabulary in
                let cleaner: any TranscriptCleaner = settings.cleanupEngine == .apple ? appleCleaner :
                    OllamaTranscriptCleaner(endpoint: { settings.ollamaEndpoint },
                                            apiKey: { (try? KeychainStore.ollamaAPIKey.read()) ?? nil },
                                            consent: { settings.cloudConsent })
                return try await cleaner.clean(raw, vocabulary: vocabulary)
            },
            insert: { try await inserter.insert($0, to: $1) },
            prewarm: { recorder.prewarm(deviceUID: $0) },
            beginMute: { mute.begin(enabled: $0) },
            endMute: { mute.end() }
        )
    }
}

#if DEBUG
extension DictationEffects {
    /// Host XCTest sin permisos, hardware, proveedores, llavero ni configuración compartida.
    /// Los tests del controlador inyectan sus propios efectos; estos fallan si se invocan.
    static var isolatedTestHost: DictationEffects {
        DictationEffects(canPost: { false }, target: { nil }, requestMicrophone: { false },
                         prepare: { _ in throw DictationFailure.speechUnavailable },
                         startCapture: { _ in throw DictationFailure.audioEngine }, stopCapture: {},
                         transcribe: { _, _ in throw DictationFailure.transcription },
                         clean: { _, _ in throw OllamaFailure.transport },
                         insert: { _, _ in throw DictationFailure.insertion },
                         prewarm: { _ in }, beginMute: { _ in }, endMute: { true })
    }
}
#endif
