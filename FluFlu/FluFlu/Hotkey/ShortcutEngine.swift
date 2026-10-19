import AppKit

/// Vista mínima de un evento de teclado, independiente de `NSEvent` o `CGEvent` para poder probar el motor.
nonisolated struct KeyEventSnapshot: Equatable, Sendable {
    enum Kind: Sendable { case keyDown, keyUp, flagsChanged }

    let kind: Kind
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let isRepeat: Bool
    /// Momento del evento en nanosegundos de `mach_absolute_time` (la marca de CGEvent); 0 = desconocido.
    let timestamp: UInt64

    init(kind: Kind, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false, timestamp: UInt64 = 0) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(KeyShortcut.relevantModifiers.union(.function))
        self.isRepeat = isRepeat
        self.timestamp = timestamp
    }
}

/// Decide, por cada evento, qué acciones cambian de estado y si el evento debe consumirse
/// para que no llegue a la app activa. Es puro y síncrono porque el tap de CGEvent exige
/// responder en el propio callback.
nonisolated struct ShortcutEngine: Sendable {
    struct Transition: Equatable, Sendable {
        let action: ShortcutAction
        let pressed: Bool
        /// Marca del evento que la produjo (ver `KeyEventSnapshot.timestamp`).
        var timestamp: UInt64 = 0
    }

    struct Outcome: Equatable, Sendable {
        var transitions: [Transition] = []
        var swallow = false
    }

    private(set) var bindings: [ShortcutAction: KeyShortcut]
    /// Con `true`, las modificadoras solas también se consumen: otras apps con atajos sobre esa
    /// misma tecla (p. ej. doble toque de Opción) dejan de verla. El estado HID de la modificadora
    /// no cambia, así que ⌥+tecla sigue funcionando aunque se pulse con la tecla reservada.
    private(set) var reservesModifierKeys: Bool
    private var held: Set<ShortcutAction> = []

    init(bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool = false) {
        self.bindings = bindings
        self.reservesModifierKeys = reservesModifierKeys
    }

    mutating func rebind(_ bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool) {
        self.bindings = bindings
        self.reservesModifierKeys = reservesModifierKeys
        held = []
    }

    mutating func handle(_ event: KeyEventSnapshot) -> Outcome {
        var outcome = Outcome()
        for (action, shortcut) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            switch (event.kind, shortcut.kind) {
            case (.keyDown, .key):
                guard shortcut.keyCode == event.keyCode,
                      shortcut.modifiers == event.modifiers.intersection(KeyShortcut.relevantModifiers) else { continue }
                // Se consume también la repetición automática: si no, la app activa recibiría ráfagas.
                outcome.swallow = true
                if !event.isRepeat, !held.contains(action) {
                    held.insert(action)
                    outcome.transitions.append(Transition(action: action, pressed: true, timestamp: event.timestamp))
                }
            case (.keyUp, .key):
                // Al soltar no se exigen los modificadores: el usuario suele soltarlos antes que la tecla.
                guard shortcut.keyCode == event.keyCode, held.contains(action) else { continue }
                held.remove(action)
                outcome.swallow = true
                outcome.transitions.append(Transition(action: action, pressed: false, timestamp: event.timestamp))
            case (.flagsChanged, .modifierOnly):
                guard shortcut.keyCode == event.keyCode,
                      let flag = KeyLabels.modifierKeyCodes[shortcut.keyCode]?.flag else { continue }
                let pressed = event.modifiers.contains(flag)
                if reservesModifierKeys { outcome.swallow = true }
                if pressed, !held.contains(action) {
                    held.insert(action)
                    outcome.transitions.append(Transition(action: action, pressed: true, timestamp: event.timestamp))
                } else if !pressed, held.contains(action) {
                    held.remove(action)
                    outcome.transitions.append(Transition(action: action, pressed: false, timestamp: event.timestamp))
                }
            default:
                continue
            }
        }
        return outcome
    }
}
