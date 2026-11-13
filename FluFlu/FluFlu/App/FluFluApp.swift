import SwiftUI

/// Barra de menús sin ventana principal (`LSUIElement`): la app vive en el icono y en la tecla de dictado.
@main
struct FluFluApp: App {
    @State private var settings: AppSettings
    @State private var controller: DictationController

    init() {
        #if DEBUG
        if Self.isIsolatedTestHost {
            let settings = AppSettings(defaults: UserDefaults(suiteName: "FluFluTests.host.\(UUID().uuidString)")!)
            _settings = State(initialValue: settings)
            _controller = State(initialValue: DictationController(settings: settings, effects: .isolatedTestHost))
            return
        }
        #endif
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _controller = State(initialValue: DictationController(settings: settings))
    }

    /// La identidad de validación evita que macOS redirija el ítem de inicio de la app instalada.
    private static var isIsolatedTestHost: Bool {
        #if DEBUG
        Bundle.main.bundleIdentifier?.contains(".Validation.") == true
            && NSClassFromString("XCTestCase") != nil
        #else
        false
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            if Self.isIsolatedTestHost { Text("FluFlu: validación aislada") }
            else { MenuBarView(controller: controller, settings: settings) }
        } label: {
            Image(systemName: controller.phase.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            if !Self.isIsolatedTestHost { SettingsView(settings: settings, controller: controller) }
        }

        // Se abre sola en el primer arranque; después, solo desde el menú.
        Window("Bienvenida a FluFlu", id: OnboardingView.windowID) {
            if !Self.isIsolatedTestHost { OnboardingView(settings: settings, controller: controller) }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(Self.isIsolatedTestHost || settings.onboardingCompleted ? .suppressed : .presented)
    }
}
