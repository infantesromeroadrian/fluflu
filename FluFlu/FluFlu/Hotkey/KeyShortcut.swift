import AppKit

/// Acciones con atajo. Hoy solo hay una: la tecla de dictado, que entiende tres gestos
/// (mantener, toque para fijar y toque para terminar) resueltos por `DictationGesture`.
nonisolated enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case dictate

    var title: String {
        switch self {
        case .dictate: "Tecla de dictado"
        }
    }
}

/// Un atajo grabado por el usuario. `kind` distingue una combinación normal (tecla + modificadores)
/// de una modificadora sola (p. ej. Opción derecha), que llega por `flagsChanged` y nunca se consume.
nonisolated struct KeyShortcut: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case key
        case modifierOnly
    }

    /// Solo estos modificadores cuentan para comparar; `function`, bloq. mayús y teclado numérico
    /// los añade el sistema y harían que un mismo atajo coincidiera o no según la tecla.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static let rightOption = KeyShortcut(kind: .modifierOnly, keyCode: 61, modifiers: .option, label: "Opción derecha")

    let kind: Kind
    let keyCode: UInt16
    let modifiersRawValue: UInt
    /// Etiqueta de la tecla capturada al grabar (depende de la distribución del teclado).
    let label: String

    init(kind: Kind, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, label: String) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiersRawValue = modifiers.intersection(Self.relevantModifiers).rawValue
        self.label = label
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRawValue) }

    /// Texto al estilo de macOS: ⌃⌥⇧⌘ seguido de la tecla.
    var displayString: String {
        switch kind {
        case .modifierOnly:
            return label
        case .key:
            var symbols = ""
            if modifiers.contains(.control) { symbols += "⌃" }
            if modifiers.contains(.option) { symbols += "⌥" }
            if modifiers.contains(.shift) { symbols += "⇧" }
            if modifiers.contains(.command) { symbols += "⌘" }
            return symbols + label
        }
    }

    enum ValidationFailure: Error, Equatable {
        /// Una tecla corriente sin modificador se la robaríamos a todas las apps.
        case needsModifier
    }

    func validate() throws(ValidationFailure) {
        guard kind == .key, modifiers.isEmpty, !KeyLabels.isStandaloneSafe(keyCode) else { return }
        throw .needsModifier
    }
}

/// Etiquetas y clasificación de teclas por código virtual (distribución ANSI/ISO de Apple).
nonisolated enum KeyLabels {
    private static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Espacio", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]

    static let modifierKeyCodes: [UInt16: (label: String, flag: NSEvent.ModifierFlags)] = [
        54: ("Comando derecho", .command), 55: ("Comando izquierdo", .command),
        58: ("Opción izquierda", .option), 61: ("Opción derecha", .option),
        59: ("Control izquierdo", .control), 62: ("Control derecho", .control),
        56: ("Mayúsculas izquierda", .shift), 60: ("Mayúsculas derecha", .shift),
        63: ("Fn / Globo", .function),
    ]

    private static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80]

    /// Teclas que no escriben nada y pueden ir solas: F1–F19.
    static func isStandaloneSafe(_ keyCode: UInt16) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    static func label(keyCode: UInt16, characters: String?) -> String {
        if let known = special[keyCode] { return known }
        if let characters, let first = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(first) {
            return characters.uppercased()
        }
        return "Tecla \(keyCode)"
    }
}
