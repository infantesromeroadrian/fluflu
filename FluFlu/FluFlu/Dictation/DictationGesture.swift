import Foundation

/// Interpreta la tecla de dictado como dos gestos: mantener (dicta hasta soltar) y toque corto (dictado
/// fijo con las manos libres; otro toque lo termina). No hay doble pulsación: el doble toque de Opción es
/// el atajo de otras apps (Claude Desktop) y en la Mac App Store la tecla no se puede consumir, así que
/// las dos apps se disparaban a la vez (decisión de Adrián, 19-oct-2026).
/// Es pura: recibe instantes y devuelve órdenes, así el controlador solo ejecuta.
nonisolated struct DictationGesture: Equatable, Sendable {
    /// Soltar antes de este tiempo cuenta como toque y fija el dictado; más, como mantener.
    static let tapMaximum: Duration = .milliseconds(300)

    enum State: Equatable, Sendable {
        case idle
        /// Tecla abajo; aún no se sabe si será mantener o toque. Ya se está grabando.
        case holding(since: ContinuousClock.Instant)
        /// Dictado fijo: grabando sin tecla pulsada.
        case locked
        /// Tecla abajo durante el dictado fijo; al soltar se termina.
        case lockedStopping
    }

    enum Command: Equatable, Sendable {
        case start
        case finish
        case lock
    }

    private(set) var state: State = .idle

    mutating func pressed(at now: ContinuousClock.Instant) -> [Command] {
        switch state {
        case .idle:
            state = .holding(since: now)
            return [.start]
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
                state = .locked
                return [.lock]
            }
            state = .idle
            return [.finish]
        case .lockedStopping:
            state = .idle
            return [.finish]
        case .idle, .locked:
            return []
        }
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
