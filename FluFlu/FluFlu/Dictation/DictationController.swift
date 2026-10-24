import AppKit
import Foundation
import Observation
import OSLog

/// Orquesta un dictado completo: tecla → micrófono → motor de voz → limpieza → inserción.
/// Es el único dueño de la fase; las vistas solo la leen.
@Observable
@MainActor
final class DictationController {
    private static let log = AppLog(category: "dictation")
    /// Un fallo se muestra un rato y vuelve a `idle` para no dejar el icono en rojo indefinidamente.
    private static let failureDisplay: Duration = .seconds(6)

    private(set) var phase: DictationPhase = .idle
    private(set) var hasKeyboardAccess = KeyboardAccess.isGranted

    private let settings: AppSettings
    private let engine: any SpeechEngine
    private let inserter: TextInserter
    private var shortcuts: GlobalShortcutTap?
    private let recorder = MicrophoneRecorder()
    private let appleCleaner: AppleTranscriptCleaner
    private let hud = DictationHUD()
    private var gesture = DictationGesture()
    private var trustPolling: Task<Void, Never>?
    /// Cadencia con la que se reintenta el tap mientras falta Accesibilidad.
    private static let trustPollInterval: Duration = .seconds(2)
    private var session: Task<Void, Never>?
    private var failureReset: Task<Void, Never>?
    /// Aviso de limpieza fallida que se enseña después de pegar el texto bruto.
    private var pendingNotice: String?
    private var noticeReset: Task<Void, Never>?

    init(settings: AppSettings, engine: any SpeechEngine = AppleSpeechEngine(), inserter: TextInserter = TextInserter()) {
        self.settings = settings
        self.engine = engine
        self.inserter = inserter
        appleCleaner = AppleTranscriptCleaner(locale: { [settings] in settings.locale })
        // Sin permisos de teclado no hay atajo ni se puede pegar. En el primer arranque los pide la
        // bienvenida, que antes explica para qué; después, el diálogo del sistema directamente.
        if !hasKeyboardAccess && settings.onboardingCompleted { KeyboardAccess.promptOnce() }
        startShortcuts()
        Task { await warmUp() }
        LaunchAtLogin.applyCommandLineRequest()
        do { try KeychainStore.ollamaAPIKey.adoptOwnership() } catch {
            Self.log.warning("keychain adoption failed: \(String(describing: error))")
        }
    }

    // MARK: Permisos y preparación

    /// Estado del modelo de Apple para Ajustes; se lee al abrir la ventana porque puede cambiar
    /// (descarga del modelo, Apple Intelligence activada o no).
    var appleCleanupStatus: String { appleCleaner.statusDescription }

    func refreshPermissions() {
        hasKeyboardAccess = KeyboardAccess.isGranted
        // El tap falla sin permiso para escuchar; en cuanto se concede, se reintenta sin reiniciar la app.
        if KeyboardAccess.canListen, shortcuts?.isRunning != true { startShortcuts() }
    }

    func requestKeyboardAccess() {
        KeyboardAccess.request()
        refreshPermissions()
    }

    func applyShortcutChange() {
        shortcuts?.rebind(settings.shortcuts, reservesModifierKeys: reservesModifierKeys)
    }

    /// En la variante de la tienda el tap solo escucha: el ajuste de reservar la tecla no aplica.
    private var reservesModifierKeys: Bool { KeyboardAccess.reservesKey && settings.reservesDictationKey }

    private func startShortcuts() {
        // Con un tap de solo escucha el sistema puede crearlo sin permiso y no entregar nada: se
        // espera al permiso para no dar el atajo por activo.
        guard KeyboardAccess.canListen else { pollTrustUntilGranted(); return }
        let tap = GlobalShortcutTap(bindings: settings.shortcuts, reservesModifierKeys: reservesModifierKeys) { [weak self] transition in
            self?.handle(transition)
        }
        if tap.start() {
            shortcuts = tap
            Self.log.info("keyboard tap started; keyboard access=\(self.hasKeyboardAccess)")
            // En la tienda escuchar y pegar son permisos distintos: se sigue esperando el de pegar.
            if !KeyboardAccess.isGranted { pollTrustUntilGranted() }
        } else {
            Self.log.error("keyboard tap NOT started; keyboard access=\(self.hasKeyboardAccess)")
            pollTrustUntilGranted()
        }
    }

    /// macOS no avisa cuando el usuario concede un permiso con la app abierta: se consulta hasta tener
    /// todos. Cada vuelta actualiza el estado que ven el menú y Ajustes, y arranca el tap en cuanto se
    /// puede escuchar aunque falte el permiso de pegar.
    private func pollTrustUntilGranted() {
        guard trustPolling == nil else { return }
        trustPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.trustPollInterval)
                guard let self else { return }
                self.refreshPermissions()
                if KeyboardAccess.isGranted {
                    self.trustPolling = nil
                    return
                }
            }
        }
    }

    /// Descarga el modelo del idioma al arrancar para que la primera pulsación no espere.
    func warmUp() async {
        recorder.prewarm(deviceUID: settings.inputDeviceUID)
        if settings.cleanupEnabled && settings.cleanupEngine == .apple { appleCleaner.prewarm() }
        do { try await engine.prepare(locale: settings.locale) } catch {
            Self.log.error("warm-up failed: \(String(describing: error))")
        }
    }

    // MARK: Ciclo de un dictado

    private func handle(_ transition: ShortcutEngine.Transition) {
        Self.log.info("shortcut \(transition.pressed ? "pressed" : "released") in state \(String(describing: self.gesture.state).prefix(16)) lag=\(transition.timestamp > 0 ? (DispatchTime.now().uptimeNanoseconds &- transition.timestamp) / 1_000_000 : 0) ms")
        let now = Self.instant(ofEventAt: transition.timestamp)
        let commands = transition.pressed ? gesture.pressed(at: now) : gesture.released(at: now)
        run(commands)
    }

    /// El gesto se mide con la hora del evento, no con la de su procesado: si el hilo principal está
    /// ocupado preparando el primer dictado, la suelta llega tarde y un toque parecería "mantener".
    /// La marca de CGEvent y `DispatchTime` comparten base (`mach_absolute_time` en nanosegundos).
    private static let maximumEventLag: Duration = .seconds(2)
    private static func instant(ofEventAt timestamp: UInt64) -> ContinuousClock.Instant {
        guard timestamp > 0 else { return .now }
        let uptime = DispatchTime.now().uptimeNanoseconds
        guard uptime > timestamp else { return .now }
        let lag = Duration.nanoseconds(Int64(uptime - timestamp))
        return .now - min(lag, maximumEventLag)
    }

    private func run(_ commands: [DictationGesture.Command]) {
        for command in commands {
            switch command {
            case .start: startDictation()
            case .finish: finishDictation()
            case .lock: apply(.locked)
            }
        }
    }

    private func startDictation() {
        guard !phase.isBusy else { gesture.reset(); return }
        // Sin permiso para pegar, el dictado se perdería al final, y con consentimiento ya habría salido
        // hacia Ollama: se avisa antes de grabar. Solo puede pasar en la tienda, donde escuchar y pegar se
        // conceden por separado.
        guard KeyboardAccess.canPost else { gesture.reset(); fail(.accessibilityDenied); return }
        pendingNotice = nil
        noticeReset?.cancel()
        apply(.keyPressed)
        session = Task { await record() }
    }

    private func finishDictation() {
        guard case .recording = phase else { return }
        recorder.stop()
        apply(.stopRequested)
    }

    private func record() async {
        hud.show(status: phase.statusText)
        do {
            let readyStart = ContinuousClock.now
            guard await MicrophoneRecorder.requestPermission() else { throw DictationFailure.microphoneDenied }
            try await engine.prepare(locale: settings.locale)
            Self.log.info("ready to record in \(MicrophoneRecorder.milliseconds(ContinuousClock.now - readyStart)) ms")
            // Si la tecla se soltó mientras esperábamos permisos o modelo, no hay audio que transcribir.
            guard case .recording = phase else { gesture.reset(); apply(.reset); hud.hide(); return }
            try recorder.start(deviceUID: settings.inputDeviceUID)
            let outcome = try await engine.transcribe(recorder.ingress, locale: settings.locale) { [weak self] partial in
                self?.apply(.partialTranscript(partial))
            }
            guard !Task.isCancelled else { return }
            apply(.transcriptReady(outcome.text))
            guard case .cleaning(let raw) = phase else { hud.hide(); return }
            let cleaned = try await clean(raw)
            apply(.cleanupFinished(cleaned))
            guard case .inserting = phase else { finishHUD(); return }
            try await inserter.insert(cleaned)
            apply(.inserted)
            finishHUD()
        } catch let failure as DictationFailure {
            recorder.stop()
            fail(failure)
        } catch {
            recorder.stop()
            Self.log.error("dictation failed: \(String(describing: error))")
            fail(.transcription)
        }
    }

    /// La limpieza es opcional por ajuste; cuando falla, el contrato es insertar el texto bruto
    /// y avisar, porque perder un dictado entero es peor que pegarlo sin pulir.
    private func clean(_ raw: String) async throws -> String {
        guard settings.cleanupEnabled else { return raw }
        let cleaner: any TranscriptCleaner = switch settings.cleanupEngine {
        case .apple:
            appleCleaner
        case .ollama:
            OllamaTranscriptCleaner(
                endpoint: { [settings] in settings.ollamaEndpoint },
                apiKey: { (try? KeychainStore.ollamaAPIKey.read()) ?? nil },
                consent: { [settings] in settings.cloudConsent }
            )
        }
        let cleaned: String
        do {
            cleaned = try await cleaner.clean(raw, vocabulary: settings.vocabularyTerms)
        } catch OllamaFailure.consentMissing {
            // No aceptar el envío es una elección de la bienvenida o de Ajustes, no un fallo: se pega
            // el texto tal cual sin el aviso de limpieza fallida.
            return raw
        } catch let failure as any CleanupError {
            return keepRaw(raw, reason: failure.reason)
        } catch {
            Self.log.error("unexpected cleanup error: \(String(describing: type(of: error)))")
            return keepRaw(raw, reason: "error inesperado del modelo")
        }
        // Un modelo no decide tirar un dictado con palabras: tomaba órdenes dictadas («traduce
        // esto…») por instrucciones y devolvía el centinela de vacío. Solo los sonidos de relleno
        // justifican no pegar nada.
        if cleaned.isEmpty && !CleanupGuard.isOnlyFillerSounds(raw) {
            return keepRaw(raw, reason: "el modelo devolvió el dictado vacío")
        }
        return cleaned
    }

    /// Plan B de la limpieza: el texto bruto se pega igual y el aviso se muestra al terminar.
    private func keepRaw(_ raw: String, reason: String) -> String {
        Self.log.warning("cleanup failed, inserting raw transcript: \(reason)")
        pendingNotice = DictationFailure.cleanup(reason).userMessage
        return raw
    }

    /// Muestra el aviso pendiente un rato tras pegar, o cierra la HUD si no hay nada que contar.
    /// Antes el aviso se ponía durante la limpieza y la HUD lo sobrescribía en el mismo instante.
    private func finishHUD() {
        guard let notice = pendingNotice else { hud.hide(); return }
        pendingNotice = nil
        hud.show(status: notice)
        noticeReset?.cancel()
        noticeReset = Task { [weak self] in
            try? await Task.sleep(for: Self.failureDisplay)
            guard let self, !Task.isCancelled, !self.phase.isBusy else { return }
            self.hud.hide()
        }
    }

    private func apply(_ event: DictationEvent) {
        phase = DictationReducer.reduce(phase, event)
        Self.log.info("phase -> \(self.phase.logSummary)")
        hud.update(status: phase.statusText)
    }

    private func fail(_ failure: DictationFailure) {
        gesture.reset()
        apply(.failed(failure))
        hud.show(status: failure.userMessage)
        failureReset?.cancel()
        failureReset = Task { [weak self] in
            try? await Task.sleep(for: Self.failureDisplay)
            guard let self, !Task.isCancelled, case .failed = self.phase else { return }
            self.apply(.reset)
            self.hud.hide()
        }
    }
}
