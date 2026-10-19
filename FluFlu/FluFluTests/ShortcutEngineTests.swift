import AppKit
import Testing
@testable import FluFlu

struct KeyShortcutTests {
    @Test func plainKeyWithoutModifierIsRejected() {
        let shortcut = KeyShortcut(kind: .key, keyCode: 0, modifiers: [], label: "A")
        #expect(throws: KeyShortcut.ValidationFailure.needsModifier) { try shortcut.validate() }
    }

    @Test func functionKeyAloneIsAccepted() throws {
        try KeyShortcut(kind: .key, keyCode: 96, modifiers: [], label: "F5").validate()
    }

    @Test func modifierOnlyIsAccepted() throws {
        try KeyShortcut.rightOption.validate()
    }

    @Test func displayStringFollowsMacOrder() {
        let shortcut = KeyShortcut(kind: .key, keyCode: 49, modifiers: [.command, .shift, .option, .control], label: "Espacio")
        #expect(shortcut.displayString == "⌃⌥⇧⌘Espacio")
    }

    @Test func irrelevantModifiersAreDropped() {
        let shortcut = KeyShortcut(kind: .key, keyCode: 123, modifiers: [.option, .function, .numericPad], label: "←")
        #expect(shortcut.modifiers == .option)
    }

    @Test func roundTripsThroughJSON() throws {
        let bindings: [ShortcutAction: KeyShortcut] = [.dictate: .rightOption]
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode([ShortcutAction: KeyShortcut].self, from: data) == bindings)
    }
}

struct ShortcutEngineTests {
    private let optionSpace = KeyShortcut(kind: .key, keyCode: 49, modifiers: .option, label: "Espacio")

    @Test func keyShortcutPressesOnKeyDownAndIsSwallowed() {
        var engine = ShortcutEngine(bindings: [.dictate: optionSpace])
        let outcome = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: .option))
        #expect(outcome == ShortcutEngine.Outcome(transitions: [.init(action: .dictate, pressed: true)], swallow: true))
    }

    @Test func autoRepeatIsSwallowedWithoutNewTransition() {
        var engine = ShortcutEngine(bindings: [.dictate: optionSpace])
        _ = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: .option))
        let outcome = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: .option, isRepeat: true))
        #expect(outcome == ShortcutEngine.Outcome(transitions: [], swallow: true))
    }

    @Test func modifiersMustMatchExactly() {
        var engine = ShortcutEngine(bindings: [.dictate: optionSpace])
        let extra = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: [.option, .shift]))
        let none = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: []))
        #expect(extra == ShortcutEngine.Outcome())
        #expect(none == ShortcutEngine.Outcome())
    }

    @Test func keyUpReleasesEvenIfModifiersWentFirst() {
        var engine = ShortcutEngine(bindings: [.dictate: optionSpace])
        _ = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: .option))
        _ = engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 58, modifiers: []))
        let outcome = engine.handle(KeyEventSnapshot(kind: .keyUp, keyCode: 49, modifiers: []))
        #expect(outcome == ShortcutEngine.Outcome(transitions: [.init(action: .dictate, pressed: false)], swallow: true))
    }

    @Test func unrelatedKeyUpIsNotSwallowed() {
        var engine = ShortcutEngine(bindings: [.dictate: optionSpace])
        #expect(engine.handle(KeyEventSnapshot(kind: .keyUp, keyCode: 49, modifiers: [])) == ShortcutEngine.Outcome())
    }

    @Test func modifierOnlyShortcutIsNeverSwallowed() {
        var engine = ShortcutEngine(bindings: [.dictate: .rightOption])
        let press = engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 61, modifiers: .option))
        let release = engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 61, modifiers: []))
        #expect(press == ShortcutEngine.Outcome(transitions: [.init(action: .dictate, pressed: true)], swallow: false))
        #expect(release == ShortcutEngine.Outcome(transitions: [.init(action: .dictate, pressed: false)], swallow: false))
    }

    @Test func reservedModifierKeyIsSwallowedButOthersPassThrough() {
        var engine = ShortcutEngine(bindings: [.dictate: .rightOption], reservesModifierKeys: true)
        let press = engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 61, modifiers: .option))
        #expect(press == ShortcutEngine.Outcome(transitions: [.init(action: .dictate, pressed: true)], swallow: true))
        #expect(engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 58, modifiers: .option)) == ShortcutEngine.Outcome())
        let release = engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 61, modifiers: []))
        #expect(release == ShortcutEngine.Outcome(transitions: [.init(action: .dictate, pressed: false)], swallow: true))
    }

    @Test func leftAndRightModifiersAreDistinct() {
        var engine = ShortcutEngine(bindings: [.dictate: .rightOption])
        #expect(engine.handle(KeyEventSnapshot(kind: .flagsChanged, keyCode: 58, modifiers: .option)) == ShortcutEngine.Outcome())
    }

    @Test func rebindDropsHeldState() {
        var engine = ShortcutEngine(bindings: [.dictate: optionSpace])
        _ = engine.handle(KeyEventSnapshot(kind: .keyDown, keyCode: 49, modifiers: .option))
        engine.rebind([.dictate: .rightOption], reservesModifierKeys: false)
        #expect(engine.handle(KeyEventSnapshot(kind: .keyUp, keyCode: 49, modifiers: [])) == ShortcutEngine.Outcome())
    }
}
