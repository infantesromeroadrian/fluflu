import AppKit
import SwiftUI

/// Fila de Ajustes para una acción: muestra el atajo, permite grabarlo y quitarlo.
struct ShortcutRow: View {
    let action: ShortcutAction
    @Bindable var settings: AppSettings
    let controller: DictationController

    @State private var isRecording = false
    @State private var validationMessage: String?

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 8) {
                ShortcutRecorderField(isRecording: $isRecording, current: settings.shortcuts[action]) { recorded in
                    commit(recorded)
                }
                .frame(width: 170, height: 24)
                if settings.shortcuts[action] != nil {
                    Button("Quitar") { commit(nil) }
                }
            }
        }
        if let validationMessage {
            Text(validationMessage).font(.caption).foregroundStyle(.red)
        }
    }

    private func commit(_ shortcut: KeyShortcut?) {
        isRecording = false
        if let shortcut {
            do { try shortcut.validate() } catch {
                validationMessage = "\(shortcut.displayString) escribiría en las apps: añade un modificador."
                return
            }
            if let taken = settings.shortcuts.first(where: { $0.key != action && $0.value == shortcut }) {
                validationMessage = "Ese atajo ya lo usa «\(taken.key.title)»."
                return
            }
        }
        validationMessage = nil
        settings.shortcuts[action] = shortcut
        controller.applyShortcutChange()
    }
}

/// Campo que, mientras graba, captura la siguiente combinación de teclas desde la ventana de Ajustes.
struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var isRecording: Bool
    let current: KeyShortcut?
    let onRecord: (KeyShortcut) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { shortcut in
            onRecord(shortcut)
        }
        view.onRecordingChanged = { recording in
            isRecording = recording
        }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.current = current
        if !isRecording && view.isRecording { view.stopRecording() }
    }
}

@MainActor
final class RecorderView: NSView {
    var current: KeyShortcut? { didSet { needsDisplay = true } }
    var onRecord: (KeyShortcut) -> Void = { _ in }
    var onRecordingChanged: (Bool) -> Void = { _ in }
    private(set) var isRecording = false
    /// Modificadora pulsada en solitario; se confirma como atajo si se suelta sin tocar otra tecla.
    private var pendingModifierKeyCode: UInt16?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        pendingModifierKeyCode = nil
        onRecordingChanged(true)
        needsDisplay = true
    }

    func stopRecording() {
        isRecording = false
        pendingModifierKeyCode = nil
        onRecordingChanged(false)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return true
    }

    /// Captura también ⌘-combos antes de que el menú los interprete.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 && event.modifierFlags.intersection(KeyShortcut.relevantModifiers).isEmpty {
            stopRecording()
            return
        }
        let shortcut = KeyShortcut(kind: .key, keyCode: event.keyCode, modifiers: event.modifierFlags,
                                   label: KeyLabels.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
        stopRecording()
        onRecord(shortcut)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        let code = event.keyCode
        guard let modifier = KeyLabels.modifierKeyCodes[code] else { return }
        let pressed = event.modifierFlags.contains(modifier.flag)
        if pressed {
            pendingModifierKeyCode = code
        } else if pendingModifierKeyCode == code,
                  event.modifierFlags.intersection(KeyShortcut.relevantModifiers.union(.function)).isEmpty {
            let shortcut = KeyShortcut(kind: .modifierOnly, keyCode: code, modifiers: modifier.flag, label: modifier.label)
            stopRecording()
            onRecord(shortcut)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = isRecording ? "Pulsa el atajo…" : (current?.displayString ?? "Sin atajo")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: current == nil && !isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
