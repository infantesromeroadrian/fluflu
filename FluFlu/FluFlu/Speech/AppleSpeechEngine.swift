import AVFoundation
import OSLog
import Speech

/// Motor on-device de Apple (macOS 26+). El audio no abandona el Mac.
@MainActor
final class AppleSpeechEngine: SpeechEngine {
    /// Retener el modelo durante toda la vida del proceso evita recargarlo en cada pulsación.
    private static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    private static let log = AppLog(category: "speech")
    private var preparedLocale: Locale?

    func prepare(locale: Locale) async throws {
        if preparedLocale == locale { return }
        guard SpeechTranscriber.isAvailable else { throw DictationFailure.speechUnavailable }
        let resolved = try await Self.resolvedLocale(locale)
        let module = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw DictationFailure.speechAssetsMissing }
        preparedLocale = locale
    }

    func transcribe(_ ingress: AudioIngress, locale: Locale, onPartial: @escaping @MainActor (String) -> Void) async throws -> TranscriptionOutcome {
        let resolved = try await Self.resolvedLocale(locale)
        let transcriber = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules, options: Self.analyzerOptions)
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        try await analyzer.prepareToAnalyze(in: nil)

        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(AudioIngress.capacity))

        // Lector de resultados: acumula los finales y expone el volátil más reciente para la HUD.
        let reader = Task<[String], any Error> { @MainActor in
            var finals: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                Self.log.info("result final=\(result.isFinal) range=\(result.range.start.seconds)+\(result.range.duration.seconds) chars=\(text.count)")
                if result.isFinal {
                    finals.append(text)
                    onPartial(Self.join(finals))
                } else {
                    onPartial(Self.join(finals + [text]))
                }
            }
            return finals
        }
        let analysis = Task { try await analyzer.start(inputSequence: input) }
        let feeder = Task {
            defer { continuation.finish() }
            for await packet in ingress.stream {
                let item = try converter.convert(packet.buffer)
                if case .dropped = continuation.yield(item) { throw DictationFailure.transcription }
            }
            if ingress.didOverflow { throw DictationFailure.transcription }
        }

        do {
            try await feeder.value
            Self.log.info("input finished; finalizing")
            try await analysis.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            Self.log.info("analyzer finished; awaiting results")
            let finals = try await reader.value
            Self.log.info("finals=\(finals.count)")
            return TranscriptionOutcome(text: Self.join(finals))
        } catch {
            feeder.cancel(); analysis.cancel(); reader.cancel()
            await analyzer.cancelAndFinishNow()
            throw error as? DictationFailure ?? DictationFailure.transcription
        }
    }

    private static func resolvedLocale(_ locale: Locale) async throws -> Locale {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationFailure.speechUnavailable
        }
        return resolved
    }

    /// Los segmentos finales ya traen su propio espaciado inicial; se recorta solo en los extremos.
    nonisolated static func join(_ segments: [String]) -> String {
        segments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
