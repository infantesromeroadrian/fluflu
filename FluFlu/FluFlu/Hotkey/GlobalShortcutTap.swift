import AppKit
import OSLog

/// Estado compartido con el callback C del tap. El lock protege el motor; el handler reenvía
/// las transiciones al actor principal sin bloquear el hilo de eventos.
nonisolated final class ShortcutTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: ShortcutEngine
    private var port: CFMachPort?
    let handler: @Sendable (ShortcutEngine.Transition) -> Void

    init(engine: ShortcutEngine, handler: @escaping @Sendable (ShortcutEngine.Transition) -> Void) {
        self.engine = engine
        self.handler = handler
    }

    func rebind(_ bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool) {
        lock.lock(); engine.rebind(bindings, reservesModifierKeys: reservesModifierKeys); lock.unlock()
    }

    func attach(port: CFMachPort) {
        lock.lock(); self.port = port; lock.unlock()
    }

    func reenable() {
        lock.lock(); let port = self.port; lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    func handle(_ snapshot: KeyEventSnapshot) -> Bool {
        lock.lock()
        let outcome = engine.handle(snapshot)
        lock.unlock()
        for transition in outcome.transitions { handler(transition) }
        return outcome.swallow
    }
}

/// Tap de sesión sobre el teclado. A diferencia de `NSEvent.addGlobalMonitor`, puede consumir
/// el atajo para que la app activa no lo reciba; eso exige Accesibilidad. En la variante de la Mac App
/// Store (sandbox) el tap solo escucha, con Monitorización de entrada, y la tecla llega también a la app activa.
@MainActor
final class GlobalShortcutTap {
    private static let log = AppLog(category: "shortcuts")
    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    #if APP_STORE
    private static let tapOptions: CGEventTapOptions = .listenOnly
    #else
    private static let tapOptions: CGEventTapOptions = .defaultTap
    #endif

    private let state: ShortcutTapState
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { port != nil }

    init(bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool, onTransition: @escaping @MainActor (ShortcutEngine.Transition) -> Void) {
        state = ShortcutTapState(engine: ShortcutEngine(bindings: bindings, reservesModifierKeys: reservesModifierKeys)) { transition in
            Task { @MainActor in onTransition(transition) }
        }
    }

    func rebind(_ bindings: [ShortcutAction: KeyShortcut], reservesModifierKeys: Bool) {
        state.rebind(bindings, reservesModifierKeys: reservesModifierKeys)
    }

    /// Devuelve `false` si el sistema no concede el tap (normalmente, falta Accesibilidad).
    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let refcon = Unmanaged.passUnretained(state).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: Self.tapOptions,
                                           eventsOfInterest: Self.eventMask, callback: Self.callback, userInfo: refcon) else {
            Self.log.warning("event tap unavailable; keyboard permission not granted?")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        state.attach(port: port)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<ShortcutTapState>.fromOpaque(refcon).takeUnretainedValue()
        let kind: KeyEventSnapshot.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS desactiva el tap si tarda en responder; se vuelve a activar y se deja pasar el evento.
            state.reenable()
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
        let snapshot = KeyEventSnapshot(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            timestamp: event.timestamp
        )
        return state.handle(snapshot) ? nil : Unmanaged.passUnretained(event)
    }
}
