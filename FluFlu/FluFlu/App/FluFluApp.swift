import SwiftUI

/// Barra de menús sin ventana principal (`LSUIElement`): la app vive en el icono y en la tecla de dictado.
@main
struct FluFluApp: App {
    @State private var settings: AppSettings
    @State private var controller: DictationController

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _controller = State(initialValue: DictationController(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller, settings: settings)
        } label: {
            Image(systemName: controller.phase.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: settings, controller: controller)
        }

        // Se abre sola en el primer arranque; después, solo desde el menú.
        Window("Bienvenida a FluFlu", id: OnboardingView.windowID) {
            OnboardingView(settings: settings, controller: controller)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(settings.onboardingCompleted ? .suppressed : .presented)
    }
}
