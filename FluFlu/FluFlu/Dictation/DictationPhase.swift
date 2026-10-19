import Foundation

/// Fallos con significado propio para el usuario; el detalle técnico va al log, no al menú.
nonisolated enum DictationFailure: Error, Equatable, Sendable {
    case microphoneDenied
    case speechUnavailable
    case speechAssetsMissing
    case accessibilityDenied
    case audioEngine
    case transcription
    case cleanup(String)
    case insertion

    var userMessage: String {
        switch self {
        case .microphoneDenied: "Sin permiso de micrófono. Actívalo en Privacidad y seguridad."
        case .speechUnavailable: "El reconocimiento de voz de Apple no está disponible en este Mac."
        case .speechAssetsMissing: "Falta descargar el modelo de voz para el idioma elegido."
        case .accessibilityDenied: "Sin permiso de Accesibilidad: no puedo pegar el texto ni leer la tecla."
        case .audioEngine: "No se pudo iniciar la captura de audio."
        case .transcription: "La transcripción falló."
        case .cleanup(let reason): "La limpieza falló: \(reason)"
        case .insertion: "No se pudo insertar el texto en la app activa."
        }
    }

    /// Nombre del caso para el registro, sin el motivo.
    var logName: String {
        switch self {
        case .microphoneDenied: "microphoneDenied"
        case .speechUnavailable: "speechUnavailable"
        case .speechAssetsMissing: "speechAssetsMissing"
        case .accessibilityDenied: "accessibilityDenied"
        case .audioEngine: "audioEngine"
        case .transcription: "transcription"
        case .cleanup: "cleanup"
        case .insertion: "insertion"
        }
    }
}

/// Ciclo de vida de un dictado. `rawTranscript` conserva lo transcrito hasta el momento para la HUD.
nonisolated enum DictationPhase: Equatable, Sendable {
    case idle
    case recording(partial: String, locked: Bool = false)
    case transcribing
    case cleaning(raw: String)
    case inserting
    case failed(DictationFailure)

    var menuBarSymbol: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing, .cleaning, .inserting: "ellipsis.circle"
        case .failed: "mic.slash"
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Listo"
        case .recording(let partial, let locked):
            if !partial.isEmpty { return partial }
            return locked ? "Escuchando (manos libres). Pulsa la tecla para terminar." : "Escuchando…"
        case .transcribing:
            return "Transcribiendo…"
        case .cleaning:
            return "Limpiando el texto…"
        case .inserting:
            return "Insertando…"
        case .failed(let failure):
            return failure.userMessage
        }
    }

    /// Para el registro: el caso y la longitud del texto, nunca lo dictado. El fichero de registro
    /// persiste en disco y antes guardaba trozos de cada dictado.
    var logSummary: String {
        switch self {
        case .idle: "idle"
        case .recording(let partial, let locked): "recording(chars: \(partial.count), locked: \(locked))"
        case .transcribing: "transcribing"
        case .cleaning(let raw): "cleaning(chars: \(raw.count))"
        case .inserting: "inserting"
        case .failed(let failure): "failed(\(failure.logName))"
        }
    }

    var isBusy: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }
}

/// Eventos que mueven la fase. La reducción es pura para poder probar la precedencia sin audio ni red.
nonisolated enum DictationEvent: Equatable, Sendable {
    case keyPressed
    case stopRequested
    case cancelled
    case partialTranscript(String)
    /// Doble pulsación: el dictado sigue sin tecla pulsada.
    case locked
    case transcriptReady(String)
    case cleanupFinished(String)
    case inserted
    case failed(DictationFailure)
    case reset
}

nonisolated enum DictationReducer {
    static func reduce(_ phase: DictationPhase, _ event: DictationEvent) -> DictationPhase {
        switch (phase, event) {
        case (.idle, .keyPressed), (.failed, .keyPressed):
            return .recording(partial: "")
        case (.recording(_, let locked), .partialTranscript(let text)):
            return .recording(partial: text, locked: locked)
        case (.recording(let partial, _), .locked):
            return .recording(partial: partial, locked: true)
        case (.recording, .stopRequested):
            return .transcribing
        case (.recording, .cancelled):
            return .idle
        case (.transcribing, .transcriptReady(let raw)):
            return raw.isEmpty ? .idle : .cleaning(raw: raw)
        case (.cleaning, .cleanupFinished(let text)):
            return text.isEmpty ? .idle : .inserting
        case (.inserting, .inserted):
            return .idle
        case (_, .failed(let failure)):
            return .failed(failure)
        case (_, .reset):
            return .idle
        default:
            // Un evento fuera de orden (p. ej. soltar la tecla sin haberla pulsado) no cambia nada.
            return phase
        }
    }
}
