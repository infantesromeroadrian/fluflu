import Foundation
import Testing
@testable import FluFlu

@MainActor
private final class DictationFixture {
    let suite = "FluFluTests.\(UUID().uuidString)"
    let settings: AppSettings
    let defaults: UserDefaults
    var raw = "hay 12 tareas"
    var cleaned = "Hay 12 tareas."
    var cleanupFailure: OllamaFailure? = .transport
    var target: InsertionTarget? = InsertionTarget(processID: 123, launchDate: Date(timeIntervalSince1970: 1))
    var inserts: [String] = []
    var cleanupCalls = 0
    var captureStarts = 0
    var captureStops = 0
    var permission = true
    var captureFails = false
    var holdCapture = false
    var holdCleanup = false
    var holdInsertion = false
    var insertionFails = false
    var insertImplementation: (@MainActor (String, InsertionTarget) async throws -> Void)?
    var captureContinuation: CheckedContinuation<String, any Error>?
    var cleanupContinuation: CheckedContinuation<String, any Error>?
    var insertionContinuation: CheckedContinuation<Void, any Error>?
    let muteDevice = FakeMuteDevice()
    lazy var mute = OutputMuteSession(device: muteDevice)
    lazy var controller = DictationController(settings: settings, effects: DictationEffects(
        canPost: { true }, target: { self.target }, requestMicrophone: { self.permission },
        prepare: { _ in }, startCapture: { _ in
            self.captureStarts += 1
            if self.captureFails { throw DictationFailure.audioEngine }
        }, stopCapture: { self.captureStops += 1 },
        transcribe: { _, _ in
            if self.holdCapture { return try await withCheckedThrowingContinuation { self.captureContinuation = $0 } }
            return self.raw
        }, clean: { _, _ in
            self.cleanupCalls += 1
            if self.holdCleanup { return try await withCheckedThrowingContinuation { self.cleanupContinuation = $0 } }
            if let failure = self.cleanupFailure { throw failure }
            return self.cleaned
        }, insert: { text, target in
            if let insert = self.insertImplementation { try await insert(text, target); return }
            self.inserts.append(text)
            if self.holdInsertion { try await withCheckedThrowingContinuation { self.insertionContinuation = $0 } }
            if self.insertionFails { throw DictationFailure.insertion }
        }, prewarm: { _ in }, beginMute: { self.mute.begin(enabled: $0) }, endMute: { self.mute.end() }
    ))

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
        settings.recoverFailedCleanup = true
    }

    func dispose() { controller.shutdown(); defaults.removePersistentDomain(forName: suite) }

    func wait(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Controller did not reach the expected state")
    }
    var isRecovering: Bool { if case .recovery = controller.phase { true } else { false } }
}

@MainActor
struct DictationControllerTests {
    @Test func defaultsKeepExistingPolicyAndDoNotMute() {
        let fixture = DictationFixture()
        defer { fixture.dispose() }
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "FluFluTests.defaults.\(UUID().uuidString)")!)
        #expect(!fresh.recoverFailedCleanup)
        #expect(!fresh.muteOutputDuringDictation)
    }

    @Test func failureRetainsOriginalAndExplicitPasteDeliversOnce() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        #expect(f.controller.hasPendingDictation)
        #expect(f.inserts.isEmpty)
        f.controller.startDictation()
        #expect(f.captureStarts == 1)
        f.controller.pasteOriginal()
        f.controller.pasteOriginal()
        await f.wait { f.controller.phase == .idle }
        #expect(f.inserts == [f.raw])
        #expect(!f.controller.hasPendingDictation)
    }

    @Test func legacyPolicyPastesRawAfterFailure() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.settings.recoverFailedCleanup = false
        f.controller.startDictation()
        await f.wait { !f.inserts.isEmpty }
        #expect(f.inserts == [f.raw])
        #expect(!f.controller.hasPendingDictation)
    }

    @Test func unsafeOutputRetainsOriginal() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.cleanupFailure = nil
        f.cleaned = "Hay 13 tareas."
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        #expect(f.inserts.isEmpty)
        f.controller.pasteOriginal()
        await f.wait { !f.inserts.isEmpty }
        #expect(f.inserts == [f.raw])
    }

    @Test func retryDoesNotOverwritePendingAndSuccessDeliversOnce() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        f.controller.retryCleanup()
        f.controller.retryCleanup()
        await f.wait { f.isRecovering }
        #expect(f.cleanupCalls == 2)
        #expect(f.controller.hasPendingDictation)
        f.cleanupFailure = nil
        f.controller.retryCleanup()
        await f.wait { f.controller.phase == .idle }
        #expect(f.inserts == [f.cleaned])
    }

    @Test func rejectedConsentOnRetryKeepsOriginalEvenIfPolicyWasDisabled() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        f.cleanupFailure = .consentMissing
        f.settings.recoverFailedCleanup = false
        f.controller.retryCleanup()
        await f.wait { f.isRecovering }
        #expect(f.inserts.isEmpty)
        #expect(f.controller.hasPendingDictation)
    }

    @Test func discardClearsPendingAndAllowsNewDictation() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        f.controller.discardPending()
        #expect(f.controller.phase == .idle)
        #expect(!f.controller.hasPendingDictation)
        f.controller.startDictation()
        await f.wait { f.captureStarts == 2 && f.isRecovering }
        #expect(f.inserts.isEmpty)
    }

    @Test func cancelCaptureRestoresMuteAndIgnoresLateResult() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.settings.muteOutputDuringDictation = true
        f.holdCapture = true
        f.controller.startDictation()
        await f.wait { f.captureContinuation != nil }
        f.controller.cancelDictation()
        #expect(f.controller.phase == .idle)
        #expect(f.muteDevice.writes == [true, false])
        let old = f.captureContinuation
        f.captureContinuation = nil
        f.controller.startDictation()
        await f.wait { f.captureContinuation != nil }
        old?.resume(returning: "stale text")
        await Task.yield()
        #expect(f.inserts.isEmpty)
        #expect(f.controller.phase == .recording(partial: ""))
        f.controller.cancelDictation()
        f.captureContinuation?.resume(returning: f.raw)
    }

    @Test func cancelCleanupIgnoresLateOutputAndRetainsRaw() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.holdCleanup = true
        f.controller.startDictation()
        await f.wait { f.cleanupContinuation != nil }
        f.controller.cancelDictation()
        #expect(f.isRecovering)
        f.controller.pasteOriginal()
        await f.wait { f.controller.phase == .idle }
        f.cleanupContinuation?.resume(returning: f.cleaned)
        await Task.yield()
        #expect(f.inserts == [f.raw])
    }

    @Test func cancelRetryKeepsOriginalAndIgnoresLateCompletion() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        f.holdCleanup = true
        f.controller.retryCleanup()
        await f.wait { f.cleanupContinuation != nil }
        f.controller.cancelDictation()
        f.cleanupContinuation?.resume(returning: f.cleaned)
        await Task.yield()
        #expect(f.isRecovering)
        #expect(f.controller.hasPendingDictation)
        #expect(f.inserts.isEmpty)
    }

    @Test func cancellationAtInsertionCannotDuplicateDelivery() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.cleanupFailure = nil
        f.holdInsertion = true
        f.controller.startDictation()
        await f.wait { f.insertionContinuation != nil }
        f.controller.cancelDictation()
        f.controller.retryCleanup()
        f.controller.pasteOriginal()
        f.controller.startDictation()
        #expect(f.inserts == [f.cleaned])
        #expect(f.controller.phase == .inserting)
        f.insertionContinuation?.resume()
        await f.wait { f.controller.phase == .idle }
        #expect(f.inserts.count == 1)
    }

    @Test func ambiguousInsertionFailureOnlyAllowsDiscard() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.cleanupFailure = nil
        f.insertionFails = true
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        #expect(f.controller.deliveryUncertain)
        f.controller.retryCleanup()
        f.controller.pasteOriginal()
        #expect(f.inserts.count == 1)
        f.controller.discardPending()
        #expect(!f.controller.hasPendingDictation)
    }

    @Test func differentTargetPreservesPendingInsteadOfPastingElsewhere() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.holdCleanup = true
        f.controller.startDictation()
        await f.wait { f.cleanupContinuation != nil }
        let original = f.target
        f.target = InsertionTarget(processID: 124, launchDate: nil)
        f.cleanupContinuation?.resume(returning: f.cleaned)
        await f.wait { f.isRecovering }
        #expect(f.inserts.isEmpty)
        f.controller.pasteOriginal()
        await f.wait { f.isRecovering }
        #expect(f.inserts.isEmpty)
        f.target = original
        f.controller.pasteOriginal()
        await f.wait { f.controller.phase == .idle }
        #expect(f.inserts == [f.raw])
    }

    @Test(arguments: ["stop", "error", "quit"])
    func everyCaptureExitRestoresOwnedMute(exit: String) async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.settings.muteOutputDuringDictation = true
        f.holdCapture = true
        f.captureFails = exit == "error"
        f.controller.startDictation()
        if exit == "error" {
            await f.wait { if case .failed = f.controller.phase { true } else { false } }
        } else {
            await f.wait { f.captureContinuation != nil }
            if exit == "stop" { f.controller.finishDictation() } else { f.controller.shutdown() }
            f.captureContinuation?.resume(returning: f.raw)
        }
        #expect(f.muteDevice.writes == [true, false])
        #expect(f.captureStops > 0)
    }

    @Test func failedRestoreShowsActionableNoticeWithoutFailingDictation() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.settings.muteOutputDuringDictation = true
        f.holdCapture = true
        f.controller.startDictation()
        await f.wait { f.captureContinuation != nil }
        f.muteDevice.succeeds = false
        f.controller.finishDictation()
        #expect(f.controller.audioRestoreNotice != nil)
        f.captureContinuation?.resume(returning: f.raw)
        await f.wait { f.isRecovering }
        #expect(f.controller.hasPendingDictation)
    }


    @Test func retryAfterDisablingCleanupStillRequiresExplicitRawPaste() async {
        let f = DictationFixture()
        defer { f.dispose() }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        f.settings.cleanupEnabled = false
        f.controller.retryCleanup()
        await f.wait { f.isRecovering }
        #expect(f.inserts.isEmpty)
        #expect(f.cleanupCalls == 1)
        f.controller.pasteOriginal()
        await f.wait { f.controller.phase == .idle }
        #expect(f.inserts == [f.raw])
    }


    @Test func controllerPassesCapturedIdentityEvenWhenFocusChangesInsideInserter() async {
        let f = DictationFixture()
        defer { f.dispose() }
        let delivery = FakeTextInsertion()
        f.target = delivery.original
        f.cleanupFailure = nil
        delivery.beforeDispatch = { f.target = delivery.other }
        let inserter = TextInserter(effects: delivery.effects)
        f.insertImplementation = { try await inserter.insert($0, to: $1) }
        f.controller.startDictation()
        await f.wait { f.controller.phase == .idle }
        #expect(delivery.posts == [delivery.original, delivery.original])
        #expect(!f.controller.hasPendingDictation)
        #expect(delivery.clipboard == "previous clipboard")
    }

    @Test func vanishedTargetBeforeDispatchKeepsOriginalRecoverable() async {
        let f = DictationFixture()
        defer { f.dispose() }
        let delivery = FakeTextInsertion()
        f.target = delivery.original
        f.cleanupFailure = nil
        delivery.beforeDispatch = { delivery.identities[delivery.original.processID] = nil }
        let inserter = TextInserter(effects: delivery.effects)
        f.insertImplementation = { try await inserter.insert($0, to: $1) }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        #expect(delivery.posts.isEmpty)
        #expect(f.controller.hasPendingDictation)
        #expect(!f.controller.deliveryUncertain)
        #expect(delivery.clipboard == "previous clipboard")
    }

    @Test func targetReplacementAfterKeyDownPreventsRecoveryFromDuplicatingPaste() async {
        let f = DictationFixture()
        defer { f.dispose() }
        let delivery = FakeTextInsertion()
        f.target = delivery.original
        f.cleanupFailure = nil
        delivery.afterKeyDown = { delivery.identities[delivery.original.processID] = nil }
        let inserter = TextInserter(effects: delivery.effects)
        f.insertImplementation = { try await inserter.insert($0, to: $1) }
        f.controller.startDictation()
        await f.wait { f.isRecovering }
        #expect(f.controller.deliveryUncertain)
        f.controller.pasteOriginal()
        f.controller.retryCleanup()
        #expect(delivery.posts == [delivery.original])
        #expect(f.controller.hasPendingDictation)
    }

}
