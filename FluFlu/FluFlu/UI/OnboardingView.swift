import AVFoundation
import SwiftUI

/// Guía del primer arranque: permisos, clave de Ollama Cloud y consentimiento para enviar el texto.
/// Un usuario nuevo no sabe que FluFlu necesita Accesibilidad para leer la tecla y pegar, ni que el
/// texto sale del Mac para limpiarse; aquí se explica antes de pedir nada.
struct OnboardingView: View {
    static let windowID = "onboarding"
    private static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    @Bindable var settings: AppSettings
    let controller: DictationController
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var apiKey = ""
    @State private var hasStoredKey = !((try? KeychainStore.ollamaAPIKey.read()) ?? "").isEmpty
    @State private var keyMessage: String?

    private var canStart: Bool { microphone == .authorized && controller.hasKeyboardAccess }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            OnboardingStep(done: microphone == .authorized, title: "Micrófono",
                           detail: "Para escuchar mientras mantienes pulsada la tecla de dictado. El audio se reconoce en el propio Mac.") {
                microphoneAction
            }
            OnboardingStep(done: controller.hasKeyboardAccess, title: KeyboardAccess.title, detail: KeyboardAccess.detail) {
                if !controller.hasKeyboardAccess {
                    Button(KeyboardAccess.settingsButton) { controller.requestKeyboardAccess() }
                }
            }
            OnboardingStep(done: hasStoredKey, title: "Clave de Ollama Cloud",
                           detail: "FluFlu pule el texto con un modelo de lenguaje en Ollama Cloud, con tu propia cuenta.") {
                keyFields
            }
            OnboardingStep(done: settings.cloudConsent, title: "Envío del texto",
                           detail: "Se envía a ollama.com el texto reconocido y tu vocabulario, nunca el audio. Sin aceptar, FluFlu pega el texto tal como lo reconoce el Mac.") {
                Toggle("Acepto enviar el texto dictado a Ollama Cloud", isOn: $settings.cloudConsent)
                HStack {
                    Link("Privacidad de FluFlu", destination: AppLinks.privacyPolicy)
                    Link("Política de privacidad de Ollama", destination: OllamaEndpoint.privacyPolicyURL)
                }
                .font(.caption)
            }
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 520)
        // Una app de barra de menús no pasa al frente sola: sin esto la ventana nacía detrás de las demás.
        .onAppear { NSApp.activate() }
        .task { await refreshWhileVisible() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Te damos la bienvenida a FluFlu").font(.title2.bold())
                Text("Habla y FluFlu escribe por ti en cualquier app. Antes necesita esto:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var microphoneAction: some View {
        switch microphone {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button("Permitir el micrófono") {
                Task {
                    _ = await MicrophoneRecorder.requestPermission()
                    microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        default:
            // Denegado antes: macOS ya no vuelve a preguntar, solo se cambia en Ajustes del Sistema.
            Button("Abrir Ajustes del Sistema") { NSWorkspace.shared.open(Self.microphoneSettingsURL) }
        }
    }

    @ViewBuilder private var keyFields: some View {
        HStack {
            SecureField(hasStoredKey ? "Clave guardada; pega otra para cambiarla" : "Pega aquí tu clave", text: $apiKey)
                .onSubmit(saveKey)
            Button("Guardar", action: saveKey)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        HStack {
            Link("Crear una clave en ollama.com", destination: OllamaEndpoint.apiKeysURL).font(.caption)
            if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            if let shortcut = settings.shortcuts[.dictate] {
                Text("Mantén pulsada \(shortcut.displayString) para dictar y suéltala para pegar. Todo se puede cambiar en Ajustes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Empezar a dictar") {
                settings.onboardingCompleted = true
                dismissWindow(id: Self.windowID)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
            .fixedSize()
        }
    }

    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.ollamaAPIKey.write(key)
            hasStoredKey = true
            apiKey = ""
            keyMessage = "Guardada en el llavero"
        } catch {
            keyMessage = "No se pudo guardar en el llavero"
        }
    }

    /// macOS no avisa cuando se concede un permiso en Ajustes del Sistema: se consulta cada segundo
    /// mientras la ventana está abierta.
    private func refreshWhileVisible() async {
        while !Task.isCancelled {
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            controller.refreshPermissions()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private struct OnboardingStep<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action
            }
        }
    }
}
