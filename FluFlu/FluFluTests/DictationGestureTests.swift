import Testing
@testable import FluFlu

struct DictationGestureTests {
    private let t0 = ContinuousClock.Instant.now
    private var tapMax: Duration { DictationGesture.tapMaximum }

    @Test func holdingStartsOnPressAndFinishesOnRelease() {
        var gesture = DictationGesture()
        #expect(gesture.pressed(at: t0) == [.start])
        #expect(gesture.released(at: t0 + tapMax) == [.finish])
        #expect(gesture.state == .idle)
    }

    /// Un solo toque fija el dictado: ya no hace falta la doble pulsación que también abría Claude Desktop.
    @Test func singleTapLocksAndNextTapFinishes() {
        var gesture = DictationGesture()
        #expect(gesture.pressed(at: t0) == [.start])
        #expect(gesture.released(at: t0 + .milliseconds(100)) == [.lock])
        #expect(gesture.isLocked)
        #expect(gesture.pressed(at: t0 + .seconds(5)) == [])
        #expect(gesture.released(at: t0 + .seconds(5) + .milliseconds(80)) == [.finish])
        #expect(gesture.state == .idle)
    }

    /// Mantener durante el dictado fijo también lo termina al soltar, como un toque.
    @Test func longPressWhileLockedFinishesOnRelease() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        _ = gesture.released(at: t0 + .milliseconds(100))
        _ = gesture.pressed(at: t0 + .seconds(3))
        #expect(gesture.released(at: t0 + .seconds(5)) == [.finish])
        #expect(gesture.state == .idle)
    }

    @Test func repeatedPressWhileHeldIsIgnored() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        #expect(gesture.pressed(at: t0 + .milliseconds(50)) == [])
        #expect(gesture.released(at: t0 + .seconds(1)) == [.finish])
    }

    @Test func resetReturnsToIdleFromLocked() {
        var gesture = DictationGesture()
        _ = gesture.pressed(at: t0)
        _ = gesture.released(at: t0 + .milliseconds(100))
        gesture.reset()
        #expect(gesture.state == .idle)
        #expect(gesture.pressed(at: t0 + .seconds(3)) == [.start])
    }
}
