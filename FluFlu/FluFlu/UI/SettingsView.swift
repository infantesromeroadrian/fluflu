import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: DictationController

    @State private var apiKey: String = (try? KeychainStore.ollamaAPIKey.read()) ?? ""
    @State private var keychainMessage: String?
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?

    private static let locales = ["es-ES", "en-US", "en-GB", "fr-FR", "de-DE", "it-IT", "pt-BR"]

    var body: some View {
        Form {
            Section("Atajos") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action, settings: settings, controller: controller)
                }
                if KeyboardAccess.reservesKey {
                    Toggle("Reservar la tecla para FluFlu (otras apps no la verán)", isOn: $settings.reservesDictationKey)
                        .onChange(of: settings.reservesDictationKey) { controller.applyShortcutChange() }
                } else {
                    Text("La tecla de dictado también llega a la app activa: elige una que no use otra app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Mantén pulsada la tecla para dictar hasta soltar. Doble pulsación: dictado fijo con las manos libres; otra pulsación lo termina. Vale cualquier combinación; una tecla sola necesita modificador salvo F1–F19.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictado") {
                Picker("Micrófono", selection: $settings.inputDeviceUID) {
                    Text("Predeterminado del sistema").tag("")
                    ForEach(inputDevices) { Text($0.name).tag($0.uid) }
                }
                Picker("Idioma", selection: $settings.localeIdentifier) {
                    ForEach(Self.locales, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) }
                }
                .onChange(of: settings.localeIdentifier) { Task { await controller.warmUp() } }
                Toggle("Abrir FluFlu al iniciar sesión", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isInstalled)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        do { try LaunchAtLogin.setEnabled(enabled); launchAtLoginMessage = nil } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchAtLoginMessage = "No se pudo cambiar: \(error.localizedDescription)"
                        }
                    }
                if !LaunchAtLogin.isInstalled {
                    Text("Disponible cuando FluFlu está instalada en Aplicaciones.").font(.caption).foregroundStyle(.secondary)
                } else if let launchAtLoginMessage {
                    Text(launchAtLoginMessage).font(.caption).foregroundStyle(.red)
                }
                LabeledContent(KeyboardAccess.title) {
                    if controller.hasKeyboardAccess {
                        Label("Concedido", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Button("Solicitar…") { controller.requestKeyboardAccess() }
                    }
                }
            }

            Section("Limpieza del texto") {
                Toggle("Pulir el dictado con un modelo de lenguaje", isOn: $settings.cleanupEnabled)
                if CleanupEngine.offered.count > 1 {
                    Picker("Motor", selection: $settings.cleanupEngine) {
                        ForEach(CleanupEngine.offered, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: settings.cleanupEngine) { Task { await controller.warmUp() } }
                }
                switch settings.cleanupEngine {
                case .apple:
                    Text(controller.appleCleanupStatus).font(.caption).foregroundStyle(.secondary)
                case .ollama:
                    ollamaFields
                }
            }

            Section("Privacidad") {
                Link("Privacidad de FluFlu: qué sale del Mac y qué no", destination: AppLinks.privacyPolicy)
            }

            Section("Vocabulario") {
                Text("Nombres propios y términos que el modelo debe respetar, uno por línea.").font(.caption)
                TextEditor(text: $settings.vocabulary)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            controller.refreshPermissions()
            inputDevices = AudioInputDevice.available()
        }
    }

    @ViewBuilder private var ollamaFields: some View {
        Picker("Servidor", selection: $settings.ollamaHost) {
            ForEach(OllamaHost.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .onChange(of: settings.ollamaHost) { _, host in
            settings.ollamaModel = host == .cloud ? AppSettings.defaultCloudModel : AppSettings.defaultLocalModel
        }
        if settings.ollamaHost == .local {
            TextField("URL local", text: $settings.ollamaLocalURL, prompt: Text(OllamaEndpoint.defaultLocalBaseURL.absoluteString))
            if settings.ollamaEndpoint == nil {
                Text("La URL no es válida; se necesita http(s)://host[:puerto].").font(.caption).foregroundStyle(.red)
            }
        }
        TextField("Modelo", text: $settings.ollamaModel)
        if settings.ollamaEndpoint?.requiresConsent == true {
            Toggle(settings.ollamaHost == .cloud ? "Enviar el texto dictado a Ollama Cloud para limpiarlo"
                                                 : "Enviar el texto dictado a ese servidor para limpiarlo",
                   isOn: $settings.cloudConsent)
            Text("Sale el texto reconocido y tu vocabulario, nunca el audio. Sin este permiso se pega el texto sin limpiar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if settings.ollamaHost == .cloud {
            Link("Política de privacidad de Ollama", destination: OllamaEndpoint.privacyPolicyURL).font(.caption)
            SecureField("Clave de API de Ollama Cloud", text: $apiKey)
                .onSubmit(saveAPIKey)
            HStack {
                Button("Guardar clave en el llavero", action: saveAPIKey)
                if let keychainMessage { Text(keychainMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func saveAPIKey() {
        do {
            try KeychainStore.ollamaAPIKey.write(apiKey)
            keychainMessage = apiKey.trimmingCharacters(in: .whitespaces).isEmpty ? "Clave eliminada" : "Clave guardada"
        } catch {
            keychainMessage = "No se pudo guardar en el llavero"
        }
    }
}
