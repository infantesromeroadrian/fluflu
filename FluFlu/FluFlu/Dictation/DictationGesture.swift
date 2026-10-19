import Foundation

/// Interpreta la tecla de dictado como tres gestos: mantener (dicta hasta soltar), doble pulsación
/// (dictado fijo, manos libres) y una pulsación durante el dictado fijo (terminar).
/// Es pura: recibe instantes y devuelve órdenes, así el controlador solo ejecuta.
nonisolated struct DictationGesture: Equatable, Sendable {
    /// Soltar antes de este tiempo cuenta como pulsación corta; más, como mantener.
    static let tapMaximum: Duration = .milliseconds(300)
    /// Dos pulsaciones cortas dentro de esta ventana forman la doble pulsación.
    static let doubleTapWindow: Duration = .milliseconds(450)

    enum State: Equatable, Sendable {
        case idle
        /// Tecla abajo; aún no se sabe si será mantener o pulsación corta. Ya se está grabando.
        case holding(since: ContinuousClock.Instant)
        /// Pulsación corta reciente; se sigue grabando por si llega la segunda pulsación.
        case awaitingSecondTap(releasedAt: ContinuousClock.Instant)
        /// Dictado fijo: grabando sin tecla pulsada.
        case locked
        /// Tecla abajo durante el dictado fijo; al soltar se termina.
        case lockedStopping
    }

    enum Command: Equatable, Sendable {
        case start
        case finish
        case cancel
        case lock
        /// El controlador debe volver a llamar con `.timeout` en ese instante si no hubo otra pulsación.
        case scheduleTimeout(at: ContinuousClock.Instant)
    }

    private(set) var state: State = .idle

    mutating func pressed(at now: ContinuousClock.Instant) -> [Command] {
        switch state {
        case .idle:
            state = .holding(since: now)
            return [.start]
        case .awaitingSecondTap(let releasedAt):
            guard now - releasedAt <= Self.doubleTapWindow else {
                // El timeout aún no había llegado pero la ventana ya pasó: se trata como pulsación nueva.
                state = .holding(since: now)
                return [.cancel, .start]
            }
            state = .locked
            return [.lock]
        case .locked:
            state = .lockedStopping
            return []
        case .holding, .lockedStopping:
            return []
        }
    }

    mutating func released(at now: ContinuousClock.Instant) -> [Command] {
        switch state {
        case .holding(let since):
            if now - since < Self.tapMaximum {
                state = .awaitingSecondTap(releasedAt: now)
                return [.scheduleTimeout(at: now + Self.doubleTapWindow)]
            }
            state = .idle
            return [.finish]
        case .lockedStopping:
            state = .idle
            return [.finish]
        case .idle, .awaitingSecondTap, .locked:
            return []
        }
    }

    /// Venció la ventana de doble pulsación sin segunda pulsación: la corta sola se descarta.
    mutating func timeout(at now: ContinuousClock.Instant) -> [Command] {
        guard case .awaitingSecondTap(let releasedAt) = state, now - releasedAt >= Self.doubleTapWindow else { return [] }
        state = .idle
        return [.cancel]
    }

    /// El dictado terminó o falló por otra vía (p. ej. error de micrófono): el gesto vuelve a cero.
    mutating func reset() {
        state = .idle
    }

    var isLocked: Bool {
        switch state {
        case .locked, .lockedStopping: true
        default: false
        }
    }
}
