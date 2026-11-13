import AppKit

/// Los tres primeros fallos ocurren antes de publicar ningún evento. Una entrega parcial o
/// no confirmable nunca se convierte en reintento automático: ⌘V puede actuar en el key-down.
nonisolated enum TextInsertionFailure: Error, Equatable {
    case targetUnavailable
    case keyboardDenied
    case eventCreationFailed
    case deliveryUncertain

    var wasNotDispatched: Bool {
        switch self {
        case .targetUnavailable, .keyboardDenied, .eventCreationFailed: true
        case .deliveryUncertain: false
        }
    }

    var userMessage: String {
        switch self {
        case .targetUnavailable: "La aplicación de destino ya no tiene la identidad original. No se ha pegado; el dictado sigue pendiente."
        case .keyboardDenied: DictationFailure.accessibilityDenied.userMessage
        case .eventCreationFailed: "No se pudo preparar el pegado. No se ha enviado; el dictado sigue pendiente."
        case .deliveryUncertain: "No se pudo confirmar la entrega al proceso original. Comprueba el destino antes de descartar."
        }
    }
}

@MainActor
struct PreparedPasteCommand {
    let keyDown: @MainActor (Int32) -> Void
    let keyUp: @MainActor (Int32) -> Void

    func send(to target: InsertionTarget, identity: @MainActor (Int32) -> InsertionTarget?) throws {
        // La fecha impide considerar suficiente un PID reutilizado o una identidad desconocida.
        guard target.launchDate != nil, identity(target.processID) == target else {
            throw TextInsertionFailure.targetUnavailable
        }
        keyDown(target.processID)
        guard identity(target.processID) == target else { throw TextInsertionFailure.deliveryUncertain }
        keyUp(target.processID)
    }
}

/// Efectos del borde de entrega. Los tests usan un portapapeles en memoria y eventos registrados;
/// ni NSPasteboard.general ni CGEvent se ejecutan al construir el insertor con efectos inyectados.
@MainActor
struct TextInsertionEffects {
    var canPost: @MainActor () -> Bool
    var identity: @MainActor (Int32) -> InsertionTarget?
    var prepareCommand: @MainActor () throws -> PreparedPasteCommand
    /// Devuelve la restauración, también necesaria si el destino desaparece antes del despacho.
    var writeTransientText: @MainActor (String) -> (@MainActor () -> Void)
    var waitForReceiver: @MainActor () async -> Void

    static var live: TextInsertionEffects {
        TextInsertionEffects(
            canPost: { KeyboardAccess.canPost },
            identity: { processID in
                guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else { return nil }
                return InsertionTarget(processID: processID, launchDate: app.launchDate, bundleIdentifier: app.bundleIdentifier)
            },
            prepareCommand: {
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    throw TextInsertionFailure.eventCreationFailed
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                // El proceso es parte del despacho. Un cambio de foco nunca convierte el pegado
                // en un evento global y no existe fallback hacia la aplicación recién activada.
                return PreparedPasteCommand(keyDown: { down.postToPid($0) }, keyUp: { up.postToPid($0) })
            },
            writeTransientText: { text in
                let pasteboard = NSPasteboard.general
                let previous = pasteboard.string(forType: .string)
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                pasteboard.setString(text, forType: .string)
                pasteboard.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
                let changeCount = pasteboard.changeCount
                return {
                    // No borrar una copia posterior del usuario, aunque contenga el mismo texto.
                    if pasteboard.changeCount == changeCount {
                        pasteboard.clearContents()
                        if let previous { pasteboard.setString(previous, forType: .string) }
                    }
                }
            },
            waitForReceiver: { try? await Task.sleep(for: TextInserter.restoreDelay) }
        )
    }
}

/// Envía ⌘V al proceso original usando un portapapeles transitorio. No promete un campo concreto
/// ni confirmación de recepción: CGEvent.postToPid no devuelve un acknowledgement de la aplicación.
@MainActor
final class TextInserter {
    static let restoreDelay: Duration = .milliseconds(600)
    private let effects: TextInsertionEffects

    init(effects: TextInsertionEffects = .live) { self.effects = effects }

    func insert(_ text: String, to target: InsertionTarget) async throws {
        guard effects.canPost() else { throw TextInsertionFailure.keyboardDenied }
        guard target.launchDate != nil, effects.identity(target.processID) == target else {
            throw TextInsertionFailure.targetUnavailable
        }
        let command = try effects.prepareCommand()
        let restore = effects.writeTransientText(text)
        defer { restore() }
        try command.send(to: target, identity: effects.identity)
        await effects.waitForReceiver()
    }
}
