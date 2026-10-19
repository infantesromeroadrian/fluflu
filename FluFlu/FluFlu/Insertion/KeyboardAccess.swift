import AppKit

/// Permisos que necesitan el atajo global (escuchar el teclado) y el pegado (simular ⌘V).
/// Fuera de la tienda los cubre Accesibilidad, que además deja consumir la tecla. La Mac App Store
/// exige sandbox, donde Accesibilidad está prohibida: allí se usan Monitorización de entrada para
/// escuchar y el permiso PostEvent para pegar (compatibles con el sandbox según Apple DTS).
@MainActor
enum KeyboardAccess {
    #if APP_STORE
    static var canListen: Bool { CGPreflightListenEventAccess() }
    static var canPost: Bool { CGPreflightPostEventAccess() }
    /// La tecla no se puede consumir con un tap de solo escucha: también llega a las demás apps.
    static let reservesKey = false
    static let title = "Teclado"
    /// macOS lista el permiso de pegar (PostEvent) en el panel Accesibilidad: se nombra el panel real
    /// para que se encuentre, aunque FluFlu no use las funciones de accesibilidad.
    static let detail = "Monitorización de entrada, para detectar la tecla de dictado en cualquier app, y en el panel Accesibilidad, el permiso para pegar el texto. La tecla también llega a la app activa."
    static let settingsButton = "Conceder el siguiente permiso"
    private static let listenSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    private static let postSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// Si ya se mostró el diálogo de un permiso. `CGRequest*Access` solo lo enseña la primera vez y
    /// devuelve `false` al momento; recordarlo permite ir a Ajustes en vez de pedir dos veces a la vez.
    private static let askedListenKey = "keyboardAccess.askedListen"
    private static let askedPostKey = "keyboardAccess.askedPost"

    /// Un permiso cada vez: primero escuchar y después pegar. La primera vez sale el diálogo del sistema;
    /// si ya se pidió, se abre el panel de Ajustes que falta.
    static func request() {
        if !canListen {
            ask(askedListenKey, prompt: CGRequestListenEventAccess, settings: listenSettingsURL)
        } else if !canPost {
            ask(askedPostKey, prompt: CGRequestPostEventAccess, settings: postSettingsURL)
        }
    }

    /// Solo el diálogo del permiso que falte primero, sin abrir Ajustes: lo usa el arranque cuando la
    /// bienvenida ya se completó.
    static func promptOnce() {
        if !canListen { markAsked(askedListenKey); _ = CGRequestListenEventAccess() }
        else if !canPost { markAsked(askedPostKey); _ = CGRequestPostEventAccess() }
    }

    /// La petición se hace siempre: además del diálogo, es la que añade FluFlu a la lista de Ajustes (si un
    /// `tccutil reset` la quitó, el panel saldría sin ella). Ajustes solo se abre si el diálogo ya se vio.
    private static func ask(_ key: String, prompt: () -> Bool, settings: URL) {
        let askedBefore = UserDefaults.standard.bool(forKey: key)
        markAsked(key)
        if !prompt() && askedBefore { NSWorkspace.shared.open(settings) }
    }

    private static func markAsked(_ key: String) { UserDefaults.standard.set(true, forKey: key) }
    #else
    static var canListen: Bool { AXIsProcessTrusted() }
    static var canPost: Bool { AXIsProcessTrusted() }
    static let reservesKey = true
    static let title = "Accesibilidad"
    static let detail = "Para detectar la tecla de dictado desde cualquier app y pegar el texto donde estés escribiendo."
    static let settingsButton = "Abrir Ajustes de Accesibilidad"
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// La llamada añade FluFlu a la lista de Accesibilidad, pero su diálogo solo sale la primera vez:
    /// si se descartó, el panel de Ajustes es la salida que siempre existe.
    static func request() {
        // Clave literal: la constante global de ApplicationServices no es segura bajo Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(settingsURL) }
    }

    /// Solo el diálogo del sistema, sin abrir Ajustes: lo usa el arranque cuando la bienvenida ya se completó.
    static func promptOnce() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    #endif

    static var isGranted: Bool { canListen && canPost }
}
