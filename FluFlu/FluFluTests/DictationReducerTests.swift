import Testing
@testable import FluFlu

struct DictationReducerTests {
    @Test func pressingFromIdleStartsRecording() {
        #expect(DictationReducer.reduce(.idle, .keyPressed) == .recording(partial: ""))
    }

    @Test func pressingAfterFailureStartsRecording() {
        #expect(DictationReducer.reduce(.failed(.transcription), .keyPressed) == .recording(partial: ""))
    }

    @Test func cancelDiscardsRecording() {
        #expect(DictationReducer.reduce(.recording(partial: "ho"), .cancelled) == .idle)
    }

    @Test func stopRequestMovesToTranscribing() {
        #expect(DictationReducer.reduce(.recording(partial: "hola"), .stopRequested) == .transcribing)
    }

    @Test func lockKeepsPartialAndMarksRecordingLocked() {
        let phase = DictationReducer.reduce(.recording(partial: "hola"), .locked)
        #expect(phase == .recording(partial: "hola", locked: true))
        #expect(DictationReducer.reduce(phase, .partialTranscript("hola mundo")) == .recording(partial: "hola mundo", locked: true))
    }

    @Test func partialTranscriptUpdatesRecording() {
        #expect(DictationReducer.reduce(.recording(partial: ""), .partialTranscript("hola")) == .recording(partial: "hola"))
    }

    @Test func emptyTranscriptReturnsToIdleWithoutCleaning() {
        #expect(DictationReducer.reduce(.transcribing, .transcriptReady("")) == .idle)
    }

    @Test func transcriptFlowsThroughCleaningAndInsertion() {
        var phase = DictationReducer.reduce(.transcribing, .transcriptReady("hola mundo"))
        #expect(phase == .cleaning(raw: "hola mundo"))
        phase = DictationReducer.reduce(phase, .cleanupFinished("Hola, mundo."))
        #expect(phase == .inserting)
        phase = DictationReducer.reduce(phase, .inserted)
        #expect(phase == .idle)
    }

    @Test func emptyCleanupSkipsInsertion() {
        #expect(DictationReducer.reduce(.cleaning(raw: "eh"), .cleanupFinished("")) == .idle)
    }

    @Test func failureWinsFromAnyPhase() {
        for phase: DictationPhase in [.idle, .recording(partial: "x"), .transcribing, .cleaning(raw: "x"), .inserting] {
            #expect(DictationReducer.reduce(phase, .failed(.insertion)) == .failed(.insertion))
        }
    }

    @Test func outOfOrderEventsAreIgnored() {
        #expect(DictationReducer.reduce(.idle, .stopRequested) == .idle)
        #expect(DictationReducer.reduce(.transcribing, .keyPressed) == .transcribing)
        #expect(DictationReducer.reduce(.inserting, .transcriptReady("x")) == .inserting)
    }
}
