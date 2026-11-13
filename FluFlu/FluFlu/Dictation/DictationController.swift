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
    private(set) var hasKeyboardAccess: Bool
    private(set) var hasPendingDictation = false
    private(set) var deliveryUncertain = false
    private(set) var audioRestoreNotice: String?

    private let settings: AppSettings
    private let effects: DictationEffects
    private var shortcuts: DictationShortcutSource?
    private let appleCleaner: AppleTranscriptCleaner?
    private let hud: DictationHUD?
    private var pendingRaw: String?
    private var insertionTarget: InsertionTarget?
    private var sessionID: UUID?
    private var terminationObserver: DictationTerminationObserver?
    private var gesture = DictationGesture()
    private var trustPolling: Task<Void, Never>?
    /// Cadencia con la que se reintenta el tap mientras falta Accesibilidad.
    private static let trustPollInterval: Duration = .seconds(2)
    private var session: Task<Void, Never>?
    private var failureReset: Task<Void, Never>?
    /// Aviso de limpieza fallida que se enseña después de pegar el texto bruto.
    private var pendingNotice: String?
    private var noticeReset: Task<Void, Never>?

    /// La composición de producción conserva el arranque habitual. El inicializador de efectos
    /// es puro respecto al sistema, útil también para previews y pruebas funcionales aisladas.
    convenience init(settings: AppSettings, engine: any SpeechEngine = AppleSpeechEngine(), inserter: TextInserter = TextInserter()) {
        let cleaner = AppleTranscriptCleaner(locale: { [settings] in settings.locale })
        self.init(settings: settings, effects: .live(settings: settings, engine: engine,
                                                   inserter: inserter, appleCleaner: cleaner),
                  appleCleaner: cleaner, hud: DictationHUD())
        hasKeyboardAccess = KeyboardAccess.isGranted
        terminationObserver = DictationTerminationObserver { [weak self] in self?.shutdown() }
        // Sin permisos de teclado no hay atajo ni se puede pegar. En el primer arranque los pide la
        // bienvenida, que antes explica para qué; después, el diálogo del sistema directamente.
        if !hasKeyboardAccess && settings.onboardingCompleted { KeyboardAccess.promptOnce() }
        startShortcuts()
        Task { await warmUp() }
        LaunchAtLogin.applyCommandLineRequest()
        if settings.ollamaEndpoint?.requiresAPIKey == true {
            do { try KeychainStore.ollamaAPIKey.adoptOwnership() } catch {
                Self.log.warning("keychain adoption failed: \(String(describing: type(of: error)))")
            }
        }
    }

    init(settings: AppSettings, effects: DictationEffects,
         appleCleaner: AppleTranscriptCleaner? = nil, hud: DictationHUD? = nil) {
        self.settings = settings
        self.effects = effects
        self.appleCleaner = appleCleaner
        self.hud = hud
        hasKeyboardAccess = effects.canPost()
    }

    // MARK: Permisos y preparación

    /// Estado del modelo de Apple para Ajustes; se lee al abrir la ventana porque puede cambiar
    /// (descarga del modelo, Apple Intelligence activada o no).
    var appleCleanupStatus: String { appleCleaner?.statusDescription ?? "No disponible" }

    func refreshPermissions() {
        hasKeyboardAccess = KeyboardAccess.isGranted
        // El tap falla sin permiso para escuchar; en cuanto se concede, se reintenta sin reiniciar la app.
        if KeyboardAccess.canListen, shortcuts?.isRunning != true { startShortcuts() }
    }

    func requestKeyboardAccess() {
        KeyboardAccess.request()
        refreshPermissions()
    }

    /// `false` si el sistema no aceptó el atajo nuevo (en la tienda, uno que ya usa otra app).
    @discardableResult
    func applyShortcutChange() -> Bool {
        shortcuts?.rebind(settings.shortcuts, reservesModifierKeys: reservesModifierKeys) ?? true
    }

    /// En la variante de la tienda el tap solo escucha: el ajuste de reservar la tecla no aplica.
    private var reservesModifierKeys: Bool { KeyboardAccess.reservesKey && settings.reservesDictationKey }

    private func startShortcuts() {
        // Con un tap de solo escucha el sistema puede crearlo sin permiso y no entregar nada: se
        // espera al permiso para no dar el atajo por activo.
        guard KeyboardAccess.canListen else { pollTrustUntilGranted(); return }
        let tap = DictationShortcutSource(bindings: settings.shortcuts, reservesModifierKeys: reservesModifierKeys) { [weak self] transition in
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
        effects.prewarm(settings.inputDeviceUID)
        if settings.cleanupEnabled && settings.cleanupEngine == .apple { appleCleaner?.prewarm() }
        do { try await effects.prepare(settings.locale) } catch {
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

    func startDictation() {
        guard !phase.isBusy, !hasPendingDictation else {
            // Sin esta línea, una pulsación ignorada no dejaba rastro y parecía un fallo del atajo.
            Self.log.warning("dictation not started: \(self.hasPendingDictation ? "pending dictation unresolved" : "busy in \(self.phase.logSummary)")")
            gesture.reset()
            return
        }
        guard effects.canPost() else { gesture.reset(); fail(.accessibilityDenied); return }
        guard let target = effects.target() else { gesture.reset(); fail(.insertion); return }
        insertionTarget = target
        pendingNotice = nil
        noticeReset?.cancel()
        failureReset?.cancel()
        deliveryUncertain = false
        let id = UUID()
        sessionID = id
        apply(.keyPressed)
        session = Task { await record(id: id) }
    }

    func finishDictation() {
        guard case .recording = phase else { return }
        stopCapture()
        apply(.stopRequested)
    }

    private func stopCapture() {
        effects.stopCapture()
        if !effects.endMute() {
            audioRestoreNotice = "No se pudo restaurar el sonido. Comprueba el mute de la salida en Ajustes del Sistema."
        }
    }

    func cancelDictation() {
        // Una vez iniciada la inserción, el receptor podría haber recibido ⌘V. Se deja terminar
        // la restauración del portapapeles y nunca se ofrece reintentar una entrega ambigua.
        if case .inserting = phase { return }
        sessionID = nil
        session?.cancel()
        session = nil
        stopCapture()
        gesture.reset()
        if hasPendingDictation { recover(reason: "Operación cancelada; el original sigue disponible.") }
        else { apply(.reset); hud?.hide() }
    }

    func shutdown() {
        cancelDictation()
        stopCapture()
        trustPolling?.cancel()
        failureReset?.cancel()
        noticeReset?.cancel()
    }

    func discardPending() {
        guard case .recovery = phase else { return }
        clearPending()
        sessionID = nil
        apply(.reset)
        hud?.hide()
    }

    func retryCleanup() {
        guard case .recovery = phase, !deliveryUncertain, let raw = pendingRaw else { return }
        let id = UUID()
        sessionID = id
        phase = .cleaning(raw: raw)
        hud?.show(status: phase.statusText)
        session = Task { await processPending(id: id, retry: true) }
    }

    func pasteOriginal() {
        guard case .recovery = phase, !deliveryUncertain, let raw = pendingRaw else { return }
        let id = UUID()
        sessionID = id
        // Bloquea inmediatamente un segundo clic, antes de que empiece la tarea.
        phase = .cleaning(raw: raw)
        session = Task { await deliver(raw, id: id) }
    }

    private func isCurrent(_ id: UUID) -> Bool { sessionID == id && !Task.isCancelled }

    private func record(id: UUID) async {
        hud?.show(status: phase.statusText)
        do {
            guard await effects.requestMicrophone() else { throw DictationFailure.microphoneDenied }
            guard isCurrent(id) else { return }
            try await effects.prepare(settings.locale)
            guard isCurrent(id) else { return }
            guard case .recording = phase else { gesture.reset(); apply(.reset); hud?.hide(); return }
            effects.beginMute(settings.muteOutputDuringDictation)
            try effects.startCapture(settings.inputDeviceUID)
            let raw = try await effects.transcribe(settings.locale) { [weak self] partial in
                guard let self, self.sessionID == id else { return }
                self.apply(.partialTranscript(partial))
            }
            guard isCurrent(id) else { return }
            stopCapture()
            // Un motor puede terminar por sí mismo antes de soltar la tecla.
            if case .recording = phase { apply(.stopRequested) }
            gesture.reset()
            apply(.transcriptReady(raw))
            guard case .cleaning = phase else {
                Self.log.warning("empty transcript; nothing to insert")
                hud?.hide()
                return
            }
            pendingRaw = raw
            hasPendingDictation = true
            await processPending(id: id, retry: false)
        } catch {
            guard isCurrent(id) else { return }
            stopCapture()
            // Solo el tipo: la descripción de algunos errores podría citar el texto dictado.
            Self.log.error("dictation failed: \((error as? DictationFailure)?.logName ?? String(describing: type(of: error)))")
            fail((error as? DictationFailure) ?? .transcription)
        }
    }

    private func processPending(id: UUID, retry: Bool) async {
        guard let raw = pendingRaw else { return }
        if retry && !settings.cleanupEnabled {
            recover(reason: "La limpieza está desactivada. Actívala para reintentar o elige Pegar original.")
            return
        }
        do {
            var cleaned = raw
            if settings.cleanupEnabled {
                let selectedEngine = settings.cleanupEngine
                let vocabulary = settings.vocabularyTerms
                cleaned = try await effects.clean(raw, vocabulary)
                guard isCurrent(id) else { return }
                // Defensa también en el borde de entrega, incluidos limpiadores inyectados.
                if selectedEngine == .ollama && !CleanupGuard.preservesProtectedContent(
                    cleaned: cleaned, raw: raw, vocabulary: vocabulary) {
                    throw OllamaFailure.changedContent
                }
                if cleaned.isEmpty && !CleanupGuard.isOnlyFillerSounds(raw) { throw OllamaFailure.emptyResponse }
            }
            guard isCurrent(id) else { return }
            await deliver(cleaned, id: id)
        } catch {
            guard isCurrent(id) else { return }
            let reason = (error as? any CleanupError)?.reason ?? "error inesperado del modelo"
            // Los motivos son textos fijos de la app, sin contenido dictado.
            Self.log.warning("cleanup failed\(retry ? " on retry" : ""): \(reason)")
            // En un reintento nunca se transforma silenciosamente una decisión explícita en pegar
            // bruto, aunque el ajuste se haya cambiado mientras había texto pendiente.
            if settings.recoverFailedCleanup || retry {
                recover(reason: reason)
            } else {
                if (error as? OllamaFailure) != .consentMissing {
                    pendingNotice = DictationFailure.cleanup(reason).userMessage
                }
                await deliver(raw, id: id)
            }
        }
    }

    private func deliver(_ text: String, id: UUID) async {
        guard isCurrent(id) else { return }
        if text.isEmpty { clearPending(); apply(.reset); finishHUD(); return }
        guard effects.canPost() else { recover(reason: DictationFailure.accessibilityDenied.userMessage); return }
        guard let insertionTarget, effects.target() == insertionTarget else {
            recover(reason: "Vuelve a la aplicación donde empezó el dictado y elige Reintentar o Pegar original desde el menú.")
            return
        }
        phase = .inserting
        hud?.update(status: phase.statusText)
        do {
            try await effects.insert(text, insertionTarget)
            guard sessionID == id else { return }
            clearPending()
            apply(.inserted)
            finishHUD()
        } catch {
            guard sessionID == id else { return }
            if let failure = error as? TextInsertionFailure, failure.wasNotDispatched {
                recover(reason: failure.userMessage)
                return
            }
            // No se conoce si el receptor llegó a recibir el pegado. No volver a entregarlo.
            deliveryUncertain = true
            recover(reason: "No se pudo confirmar la inserción. Comprueba la aplicación de destino; solo se permite descartar para evitar duplicados.")
        }
    }

    private func clearPending() {
        pendingRaw = nil
        hasPendingDictation = false
        deliveryUncertain = false
        insertionTarget = nil
    }

    private func recover(reason: String) {
        gesture.reset()
        Self.log.warning("dictation pending: \(reason)")
        phase = .recovery(reason: reason)
        hud?.show(status: "Dictado pendiente. Abre el menú de FluFlu.")
    }

    /// Muestra el aviso pendiente un rato tras pegar, o cierra la HUD si no hay nada que contar.
    /// Antes el aviso se ponía durante la limpieza y la HUD lo sobrescribía en el mismo instante.
    private func finishHUD() {
        guard let notice = pendingNotice else { hud?.hide(); return }
        pendingNotice = nil
        hud?.show(status: notice)
        noticeReset?.cancel()
        noticeReset = Task { [weak self] in
            try? await Task.sleep(for: Self.failureDisplay)
            guard let self, !Task.isCancelled, !self.phase.isBusy else { return }
            self.hud?.hide()
        }
    }

    private func apply(_ event: DictationEvent) {
        phase = DictationReducer.reduce(phase, event)
        Self.log.info("phase -> \(self.phase.logSummary)")
        hud?.update(status: phase.statusText)
    }

    private func fail(_ failure: DictationFailure) {
        gesture.reset()
        apply(.failed(failure))
        hud?.show(status: failure.userMessage)
        failureReset?.cancel()
        failureReset = Task { [weak self] in
            try? await Task.sleep(for: Self.failureDisplay)
            guard let self, !Task.isCancelled, case .failed = self.phase else { return }
            self.apply(.reset)
            self.hud?.hide()
        }
    }
}


/// El cierre normal debe restaurar el mute antes de que termine el proceso, sin depender de
/// que el menú haya aparecido ni encolar una Task que quizá nunca llegue a ejecutarse.
@MainActor
private final class DictationTerminationObserver: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(terminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }
    @objc private func terminate() { action() }
}
