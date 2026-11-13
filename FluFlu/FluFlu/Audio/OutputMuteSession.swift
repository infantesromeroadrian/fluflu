import Foundation

nonisolated struct OutputMuteState: Equatable, Sendable {
    let deviceID: UInt32
    let uid: String
    let muted: Bool
    let writable: Bool
}

@MainActor
protocol OutputMuteObservation: AnyObject {
    /// Cambios manuales de mute posteriores al propio; cambiar la salida no cambia su dueño.
    var wasInterrupted: Bool { get }
    func stop()
}

@MainActor
protocol OutputMuteDevice: AnyObject {
    func currentOutput() -> OutputMuteState?
    func state(of owned: OutputMuteState) -> OutputMuteState?
    func observe(_ state: OutputMuteState) -> (any OutputMuteObservation)?
    func setMuted(_ muted: Bool, on state: OutputMuteState) -> Bool
}

/// Solo posee el mute que cambió esta sesión, sobre el UID original. El fallo es best-effort:
/// la captura nunca depende del soporte de mute del altavoz, monitor HDMI o interfaz externa.
@MainActor
final class OutputMuteSession {
    private let device: any OutputMuteDevice
    private var owned: OutputMuteState?
    private var observation: (any OutputMuteObservation)?

    init(device: any OutputMuteDevice) { self.device = device }

    func begin(enabled: Bool) {
        guard enabled, owned == nil, let initial = device.currentOutput(),
              initial.writable, !initial.muted, let watch = device.observe(initial) else { return }
        observation = watch
        guard device.setMuted(true, on: initial) else { release(); return }
        owned = initial
    }

    /// Se llama al dejar de capturar, también por error, cancelación y cierre normal.
    @discardableResult
    func end() -> Bool {
        guard let initial = owned else { release(); return true }
        defer { release() }
        // Dos intentos inmediatos como máximo. Cada intento revalida identidad y propiedad;
        // nunca queda una restauración pendiente capaz de pisar una sesión o decisión posterior.
        for _ in 0..<2 {
            guard observation?.wasInterrupted == false else { return true }
            guard let current = device.state(of: initial) else { continue }
            guard current.uid == initial.uid, current.deviceID == initial.deviceID else { return true }
            guard current.muted else { return true }
            guard current.writable else { return false }
            if device.setMuted(false, on: current) { return true }
        }
        return false
    }

    private func release() {
        observation?.stop()
        observation = nil
        owned = nil
    }
}
