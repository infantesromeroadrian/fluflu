import AppKit
import Carbon.HIToolbox

/// Atajos globales registrados en el sistema con `RegisterEventHotKey`. Es la vía de la Mac App Store:
/// no observa el teclado, así que no necesita Monitorización de entrada ni Accesibilidad. App Review
/// rechazó el tap de solo escucha por «acceso a pulsaciones sin fin de accesibilidad» (guía 2.4.5,
/// 2026-10-27). macOS solo entrega la combinación registrada, al pulsarla y al soltarla, y la consume:
/// la app activa no la recibe.
///
/// Limitación del sistema: exige una tecla. Una modificadora sola (Opción derecha) no se puede
/// registrar; esa forma queda para la variante de fuera de la tienda (`GlobalShortcutTap`).
@MainActor
final class SystemHotKeys {
    private static let log = AppLog(category: "shortcuts")
    /// Identifica los atajos de FluFlu entre los eventos del proceso ('FluF').
    nonisolated private static let signature: OSType = 0x466C_7546

    private let onTransition: @MainActor (ShortcutEngine.Transition) -> Void
    private var bindings: [ShortcutAction: KeyShortcut]
    private var registered: [UInt32: Registration] = [:]
    private var handler: EventHandlerRef?

    private struct Registration {
        let action: ShortcutAction
        let reference: EventHotKeyRef
    }

    var isRunning: Bool { handler != nil }

    /// `reservesModifierKeys` solo existe por paridad con `GlobalShortcutTap`: aquí no hay
    /// modificadoras solas y el sistema ya consume la combinación.
    init(bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool,
         onTransition: @escaping @MainActor (ShortcutEngine.Transition) -> Void) {
        self.bindings = bindings
        self.onTransition = onTransition
    }

    /// `false` si macOS no dejó registrar alguno: ya lo usa el sistema u otra app, o no lleva tecla.
    @discardableResult
    func rebind(_ bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool) -> Bool {
        self.bindings = bindings
        return handler == nil || register()
    }

    /// Devuelve `false` solo si no se pudo instalar el receptor de eventos. Un atajo concreto que no
    /// se registra se anota en el log y no impide arrancar: el usuario puede elegir otro en Ajustes.
    @discardableResult
    func start() -> Bool {
        if handler == nil {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            let status = InstallEventHandler(GetEventDispatcherTarget(), systemHotKeyCallback, types.count, &types,
                                             Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                Self.log.error("hot key handler not installed: status \(status)")
                handler = nil
                return false
            }
        }
        register()
        return true
    }

    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    @discardableResult
    private func register() -> Bool {
        unregister()
        var complete = true
        for (offset, binding) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() {
            let (action, shortcut) = binding
            guard shortcut.kind == .key else {
                Self.log.warning("hot key for \(action.rawValue) not registered: needs a key, not a lone modifier")
                complete = false
                continue
            }
            let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(offset + 1))
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers), identifier,
                                             GetEventDispatcherTarget(), 0, &reference)
            guard status == noErr, let reference else {
                Self.log.warning("hot key for \(action.rawValue) not registered: status \(status)")
                complete = false
                continue
            }
            registered[identifier.id] = Registration(action: action, reference: reference)
        }
        return complete
    }

    private func unregister() {
        for registration in registered.values { UnregisterEventHotKey(registration.reference) }
        registered = [:]
    }

    fileprivate func dispatch(identifier: EventHotKeyID, pressed: Bool) {
        guard identifier.signature == Self.signature, let registration = registered[identifier.id] else { return }
        // El evento se entrega al momento en el hilo principal: su hora es la actual.
        onTransition(ShortcutEngine.Transition(action: registration.action, pressed: pressed,
                                               timestamp: DispatchTime.now().uptimeNanoseconds))
    }

    nonisolated static func carbonModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return UInt32(carbon)
    }
}

/// Receptor C de los eventos de atajo. El despachador de eventos de Carbon lo invoca en el hilo principal.
private nonisolated let systemHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        Unmanaged<SystemHotKeys>.fromOpaque(pointer).takeUnretainedValue().dispatch(identifier: identifier, pressed: pressed)
    }
    return noErr
}
