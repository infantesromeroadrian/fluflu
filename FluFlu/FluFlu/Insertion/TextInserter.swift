import AppKit

/// Inserta texto en la app activa simulando ⌘V con el portapapeles como vehículo.
/// Es el camino más compatible (funciona en terminales, Electron y campos nativos); la ruta
/// por Accessibility (`AXUIElement`) queda como mejora cuando haga falta no tocar el portapapeles.
@MainActor
final class TextInserter {
    /// Tiempo que la app receptora necesita para leer el portapapeles antes de restaurarlo.
    static let restoreDelay: Duration = .milliseconds(600)
    private static let keyCodeV: CGKeyCode = 9
    /// Convención de nspasteboard.org: los gestores de historial del portapapeles no guardan este contenido.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Abre el diálogo del sistema una sola vez; después solo consulta.
    @discardableResult
    static func requestTrust() -> Bool {
        // Clave literal: la constante global de ApplicationServices no es segura bajo Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String) async throws {
        guard Self.isTrusted else { throw DictationFailure.accessibilityDenied }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        // Solo en este Mac: sin la opción, el dictado viajaba a los demás dispositivos por el
        // Portapapeles Universal. `prepareForNewContents` ya vacía el portapapeles.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        try Self.postCommandV()
        try? await Task.sleep(for: Self.restoreDelay)
        // Solo se restaura si nadie más ha escrito en el portapapeles mientras tanto.
        if pasteboard.string(forType: .string) == text {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
    }

    private static func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else {
            throw DictationFailure.insertion
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
