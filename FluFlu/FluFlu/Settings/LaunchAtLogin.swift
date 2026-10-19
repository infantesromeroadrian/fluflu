import Foundation
import ServiceManagement

/// Arranque al iniciar sesión mediante `SMAppService`. El sistema es la única fuente de verdad:
/// no se duplica el estado en UserDefaults para no pelearse con Ajustes del Sistema.
@MainActor
enum LaunchAtLogin {
    private static let log = AppLog(category: "launch")
    /// Argumento con el que el instalador pide el registro en el primer arranque de la copia instalada.
    static let enableArgument = "--enable-launch-at-login"
    /// Quita el registro sin abrir Ajustes: el sistema lo guarda por bundle ID, así que una copia antigua
    /// (p. ej. una build de Xcode) puede seguir arrancando al iniciar sesión aunque ya no se use.
    static let disableArgument = "--disable-launch-at-login"

    /// Solo una copia instalada debe registrarse: una build de desarrollo en DerivedData
    /// registrada como elemento de inicio arrancaría una versión que no es la de uso.
    static var isInstalled: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        log.info("launch at login \(enabled ? "registered" : "unregistered") (installed=\(isInstalled))")
    }

    /// Atiende `--enable-launch-at-login` o `--disable-launch-at-login` una vez por arranque; sin ellos no cambia nada.
    static func applyCommandLineRequest(arguments: [String] = CommandLine.arguments) {
        if arguments.contains(disableArgument) {
            do { try setEnabled(false) } catch { log.error("launch at login unregistration failed: \(String(describing: error))") }
            return
        }
        guard arguments.contains(enableArgument) else { return }
        guard isInstalled else { log.warning("launch at login requested but app is not in /Applications; ignored"); return }
        guard !isEnabled else { log.info("launch at login already enabled"); return }
        do { try setEnabled(true) } catch { log.error("launch at login registration failed: \(String(describing: error))") }
    }
}
