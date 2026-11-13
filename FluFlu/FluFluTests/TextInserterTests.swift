import Foundation
import Testing
@testable import FluFlu

/// Todo el borde de entrega está en memoria: no crea CGEvents ni consulta el portapapeles del Mac.
@MainActor
final class FakeTextInsertion {
    let original = InsertionTarget(processID: 123, launchDate: Date(timeIntervalSince1970: 1), bundleIdentifier: "test.original")
    let other = InsertionTarget(processID: 456, launchDate: Date(timeIntervalSince1970: 2), bundleIdentifier: "test.other")
    var identities: [Int32: InsertionTarget] = [:]
    var focused: InsertionTarget?
    var clipboard = "previous clipboard"
    var writes = 0
    var posts: [InsertionTarget] = []
    var permission = true
    var creationFails = false
    var beforeDispatch: (() -> Void)?
    var afterKeyDown: (() -> Void)?

    init() {
        identities[original.processID] = original
        identities[other.processID] = other
        focused = original
    }

    var effects: TextInsertionEffects {
        TextInsertionEffects(
            canPost: { self.permission },
            identity: { self.identities[$0] },
            prepareCommand: {
                if self.creationFails { throw TextInsertionFailure.eventCreationFailed }
                return PreparedPasteCommand(keyDown: { processID in
                    if let identity = self.identities[processID] { self.posts.append(identity) }
                    self.afterKeyDown?()
                }, keyUp: { processID in
                    if let identity = self.identities[processID] { self.posts.append(identity) }
                })
            },
            writeTransientText: { text in
                let previous = self.clipboard
                self.clipboard = text
                self.writes += 1
                self.beforeDispatch?()
                return { self.clipboard = previous }
            },
            waitForReceiver: {}
        )
    }
}

@MainActor
struct TextInserterTests {
    @Test func focusChangeBetweenCheckAndDispatchCannotRetargetPaste() async throws {
        let f = FakeTextInsertion()
        f.beforeDispatch = { f.focused = f.other }
        try await TextInserter(effects: f.effects).insert("synthetic text", to: f.original)
        #expect(f.focused == f.other)
        #expect(f.posts == [f.original, f.original])
        #expect(!f.posts.contains(f.other))
        #expect(f.clipboard == "previous clipboard")
    }

    @Test func disappearanceAfterClipboardWriteDoesNotDispatchAndRestoresClipboard() async {
        let f = FakeTextInsertion()
        f.beforeDispatch = { f.identities[f.original.processID] = nil }
        await #expect(throws: TextInsertionFailure.targetUnavailable) {
            try await TextInserter(effects: f.effects).insert("synthetic text", to: f.original)
        }
        #expect(f.posts.isEmpty)
        #expect(f.writes == 1)
        #expect(f.clipboard == "previous clipboard")
    }

    @Test(arguments: [true, false])
    func reusedPIDOrChangedBundleDoesNotReceiveEvents(changeLaunchDate: Bool) async {
        let f = FakeTextInsertion()
        let replacement = InsertionTarget(processID: f.original.processID,
                                          launchDate: changeLaunchDate ? Date(timeIntervalSince1970: 9) : f.original.launchDate,
                                          bundleIdentifier: changeLaunchDate ? f.original.bundleIdentifier : "test.replacement")
        f.beforeDispatch = { f.identities[f.original.processID] = replacement }
        await #expect(throws: TextInsertionFailure.targetUnavailable) {
            try await TextInserter(effects: f.effects).insert("synthetic text", to: f.original)
        }
        #expect(f.posts.isEmpty)
        #expect(f.clipboard == "previous clipboard")
    }

    @Test func noLaunchIdentityFailsBeforeClipboardAccess() async {
        let f = FakeTextInsertion()
        let unknown = InsertionTarget(processID: 123, launchDate: nil)
        f.identities[123] = unknown
        await #expect(throws: TextInsertionFailure.targetUnavailable) {
            try await TextInserter(effects: f.effects).insert("synthetic text", to: unknown)
        }
        #expect(f.writes == 0)
        #expect(f.posts.isEmpty)
    }

    @Test func targetReplacedAfterKeyDownIsUncertainAndNeverReceivesKeyUp() async {
        let f = FakeTextInsertion()
        let replacement = InsertionTarget(processID: 123, launchDate: Date(timeIntervalSince1970: 9))
        f.afterKeyDown = { f.identities[123] = replacement }
        await #expect(throws: TextInsertionFailure.deliveryUncertain) {
            try await TextInserter(effects: f.effects).insert("synthetic text", to: f.original)
        }
        #expect(f.posts == [f.original])
        #expect(f.clipboard == "previous clipboard")
    }

    @Test func eventCreationFailureDoesNotWriteClipboardOrDispatch() async {
        let f = FakeTextInsertion()
        f.creationFails = true
        await #expect(throws: TextInsertionFailure.eventCreationFailed) {
            try await TextInserter(effects: f.effects).insert("synthetic text", to: f.original)
        }
        #expect(f.writes == 0)
        #expect(f.posts.isEmpty)
    }

    @Test func permissionFailureDoesNotWriteClipboardOrDispatch() async {
        let f = FakeTextInsertion()
        f.permission = false
        await #expect(throws: TextInsertionFailure.keyboardDenied) {
            try await TextInserter(effects: f.effects).insert("synthetic text", to: f.original)
        }
        #expect(f.writes == 0)
        #expect(f.posts.isEmpty)
    }
}
