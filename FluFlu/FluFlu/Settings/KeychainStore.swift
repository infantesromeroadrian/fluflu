import Foundation
import Security

/// Guarda la clave de Ollama Cloud en el llavero del usuario; nunca en UserDefaults ni en logs.
nonisolated struct KeychainStore: Sendable {
    enum Failure: Error { case unexpectedStatus(OSStatus) }

    let service: String
    let account: String

    static let ollamaAPIKey = KeychainStore(service: "com.adrianinfantes.FluFlu", account: "ollama-api-key")

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    func write(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(); return }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.unexpectedStatus(update) }
        var insert = baseQuery
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
    }

    /// Un elemento creado desde fuera de la app (p. ej. con la herramienta `security`) pertenece a otra
    /// partición y macOS pregunta en cada lectura. Releerlo y volver a escribirlo lo pone a nombre de la app.
    /// Idempotente: si ya es nuestro, solo lo reescribe con el mismo valor.
    func adoptOwnership() throws {
        guard let value = try read() else { return }
        try delete()
        try write(value)
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unexpectedStatus(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
