import Testing
@testable import FluFlu

struct DictationGestureTests {
    private let t0 = ContinuousClock.Instant.now
    private var tapMax: Duration { DictationGesture.tapMaximum }
    private var window: Duration { DictationGesture.doubleTapWindow }

    @Test func holdingStartsOnPressAndFinishesOnRelease() {
        var gesture = DictationGesture()
        #expect(gesture.pressed(at: t0) == [.start])
        #expect(gesture.released(at: t0 + tapMax) == [.finish])
        #expect(gesture.state == .idle)
    }

    @Test func shortTapWaitsForSecondTapThenCancels() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        let release = t0 + .milliseconds(100)
        #expect(gesture.released(at: release) == [.scheduleTimeout(at: release + window)])
        #expect(gesture.timeout(at: release + .milliseconds(100)) == [])
        #expect(gesture.timeout(at: release + window) == [.cancel])
        #expect(gesture.state == .idle)
    }

    @Test func doubleTapLocksAndSingleTapFinishes() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        _ = gesture.released(at: t0 + .milliseconds(100))
        #expect(gesture.pressed(at: t0 + .milliseconds(300)) == [.lock])
        #expect(gesture.isLocked)
        #expect(gesture.released(at: t0 + .milliseconds(400)) == [])
        #expect(gesture.pressed(at: t0 + .seconds(5)) == [])
        #expect(gesture.released(at: t0 + .seconds(5) + .milliseconds(80)) == [.finish])
        #expect(gesture.state == .idle)
    }

    @Test func staleTimeoutAfterLockIsIgnored() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        _ = gesture.released(at: t0 + .milliseconds(100))
        _ = gesture.pressed(at: t0 + .milliseconds(300))
        #expect(gesture.timeout(at: t0 + .seconds(1)) == [])
        #expect(gesture.isLocked)
    }

    @Test func pressAfterWindowWithoutTimeoutRestarts() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        _ = gesture.released(at: t0 + .milliseconds(100))
        #expect(gesture.pressed(at: t0 + .seconds(2)) == [.cancel, .start])
    }

    @Test func resetReturnsToIdleFromLocked() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        _ = gesture.released(at: t0 + .milliseconds(100))
        _ = gesture.pressed(at: t0 + .milliseconds(200))
        gesture.reset()
        #expect(gesture.state == .idle)
        #expect(gesture.pressed(at: t0 + .seconds(3)) == [.start])
    }
}
