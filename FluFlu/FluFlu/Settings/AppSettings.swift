import Foundation
import Observation

/// Preferencias del usuario con UserDefaults como almacén. La clave de API vive en el llavero.
@Observable
final class AppSettings {
    private enum Key {
        static let localeIdentifier = "localeIdentifier"
        static let shortcuts = "shortcuts"
        static let reservesDictationKey = "reservesDictationKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupEngine = "cleanupEngine"
        static let ollamaHost = "ollamaHost"
        static let ollamaLocalURL = "ollamaLocalURL"
        static let ollamaModel = "ollamaModel"
        static let vocabulary = "vocabulary"
        static let inputDeviceUID = "inputDeviceUID"
        static let onboardingCompleted = "onboardingCompleted"
        static let cloudConsent = "cloudConsent"
    }

    static let defaultLocaleIdentifier = "es-ES"
    static let defaultCloudModel = "gemma4:31b"
    static let defaultLocalModel = "gemma4"
    static let defaultShortcuts: [ShortcutAction: KeyShortcut] = [.dictate: .rightOption]

    private let defaults: UserDefaults

    var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: Key.localeIdentifier) } }
    /// Atajos por acción, serializados como JSON. Una acción ausente no tiene atajo.
    var shortcuts: [ShortcutAction: KeyShortcut] { didSet { defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Key.shortcuts) } }
    /// Si la tecla de dictado es una modificadora sola, no dejarla pasar a otras apps (evita que un
    /// doble toque de Opción dispare también el atajo de otra app).
    var reservesDictationKey: Bool { didSet { defaults.set(reservesDictationKey, forKey: Key.reservesDictationKey) } }
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) } }
    var cleanupEngine: CleanupEngine { didSet { defaults.set(cleanupEngine.rawValue, forKey: Key.cleanupEngine) } }
    var ollamaHost: OllamaHost { didSet { defaults.set(ollamaHost.rawValue, forKey: Key.ollamaHost) } }
    var ollamaLocalURL: String { didSet { defaults.set(ollamaLocalURL, forKey: Key.ollamaLocalURL) } }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) } }
    /// Una palabra o nombre por línea; se inyecta en el prompt de limpieza para corregir ortografía.
    var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Key.vocabulary) } }
    /// UID del micrófono elegido; cadena vacía = entrada por defecto del sistema.
    var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) } }
    /// La bienvenida del primer arranque se cerró con «Empezar a dictar».
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }
    /// Consentimiento explícito para enviar el texto dictado fuera del Mac (Ollama Cloud u otro servidor).
    /// Sin él, ninguna petición sale del equipo.
    var cloudConsent: Bool { didSet { defaults.set(cloudConsent, forKey: Key.cloudConsent) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localeIdentifier = defaults.string(forKey: Key.localeIdentifier) ?? Self.defaultLocaleIdentifier
        if let data = defaults.data(forKey: Key.shortcuts), let stored = try? JSONDecoder().decode([ShortcutAction: KeyShortcut].self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = Self.defaultShortcuts
        }
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true
        // Un motor que ya no se ofrece (Apple, desde el 2026-10-19) vuelve a Ollama: sin selector en
        // Ajustes, el usuario no podría salir de él.
        let storedEngine = CleanupEngine(rawValue: defaults.string(forKey: Key.cleanupEngine) ?? "")
        cleanupEngine = storedEngine.flatMap { CleanupEngine.offered.contains($0) ? $0 : nil } ?? .ollama
        reservesDictationKey = defaults.object(forKey: Key.reservesDictationKey) as? Bool ?? true
        ollamaHost = OllamaHost(rawValue: defaults.string(forKey: Key.ollamaHost) ?? "") ?? .cloud
        ollamaLocalURL = defaults.string(forKey: Key.ollamaLocalURL) ?? OllamaEndpoint.defaultLocalBaseURL.absoluteString
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? Self.defaultCloudModel
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID) ?? ""
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        cloudConsent = defaults.bool(forKey: Key.cloudConsent)
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var vocabularyTerms: [String] {
        vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `nil` cuando la URL local no es válida: el llamador decide si avisar o bloquear.
    var ollamaEndpoint: OllamaEndpoint? {
        switch ollamaHost {
        case .cloud:
            return OllamaEndpoint(host: .cloud, baseURL: OllamaEndpoint.cloudBaseURL, model: ollamaModel)
        case .local:
            guard let url = URL(string: ollamaLocalURL), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
            return OllamaEndpoint(host: .local, baseURL: url, model: ollamaModel)
        }
    }
}
