import SwiftUI

struct MenuBarView: View {
    let controller: DictationController
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.phase.statusText)
        if let notice = controller.audioRestoreNotice { Text(notice) }
        ForEach(ShortcutAction.allCases, id: \.self) { action in
            if let shortcut = settings.shortcuts[action] {
                Text("\(shortcut.displayString): mantener para dictar · un toque para fijar").font(.caption)
            }
        }
        if settings.shortcuts.isEmpty {
            Text("Sin atajos: configúralos en Ajustes").font(.caption)
        }
        Divider()
        if case .recovery = controller.phase {
            if !controller.deliveryUncertain {
                Button("Reintentar limpieza") { controller.retryCleanup() }
                Button("Pegar original") { controller.pasteOriginal() }
            }
            Button("Descartar dictado") { controller.discardPending() }
            Divider()
        } else if controller.phase.isBusy {
            Button("Cancelar dictado") { controller.cancelDictation() }
                .disabled(controller.phase == .inserting)
            Divider()
        }
        if !controller.hasKeyboardAccess {
            Button("Permisos…") { controller.requestKeyboardAccess() }
        }
        Button("Bienvenida y permisos…") {
            openWindow(id: OnboardingView.windowID)
            NSApp.activate()
        }
        SettingsLink { Text("Ajustes…") }
            .keyboardShortcut(",")
        Button("Abrir registro de diagnóstico") { NSWorkspace.shared.open(LogFile.url) }
        Button("Acerca de FluFlu") {
            NSApp.orderFrontStandardAboutPanel(nil)
            NSApp.activate()
        }
        Divider()
        Button("Salir de FluFlu") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
