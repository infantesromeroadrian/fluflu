import AppKit
import SwiftUI

/// Panel flotante, sin foco, en la parte inferior de la pantalla con el estado y el texto parcial.
/// No activa la app: el foco debe seguir en la ventana donde se va a pegar el texto.
@MainActor
final class DictationHUD {
    private static let size = NSSize(width: 420, height: 72)
    private static let bottomMargin: CGFloat = 80

    private var panel: NSPanel?
    private let model = HUDModel()

    func show(status: String) {
        model.status = status
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func update(status: String) {
        model.status = status
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + Self.bottomMargin)
        panel.setFrameOrigin(origin)
    }
}

@Observable
@MainActor
final class HUDModel {
    var status: String = ""
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(model.status)
                .font(.body)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 420, height: 72)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
