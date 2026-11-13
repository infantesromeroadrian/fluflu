import Testing
@testable import FluFlu

@MainActor
final class FakeMuteObservation: OutputMuteObservation {
    var wasInterrupted = false
    var stopped = false
    func stop() { stopped = true }
}

@MainActor
final class FakeMuteDevice: OutputMuteDevice {
    var state: OutputMuteState? = OutputMuteState(deviceID: 42, uid: "speaker", muted: false, writable: true)
    var writes: [Bool] = []
    var otherDevices: [UInt32: OutputMuteState] = [:]
    var succeeds = true
    var readFailures = 0
    let watch = FakeMuteObservation()
    func currentOutput() -> OutputMuteState? {
        if readFailures > 0 { readFailures -= 1; return nil }
        return state
    }
    func state(of owned: OutputMuteState) -> OutputMuteState? {
        if readFailures > 0 { readFailures -= 1; return nil }
        if state?.deviceID == owned.deviceID { return state }
        return otherDevices[owned.deviceID]
    }
    func observe(_ state: OutputMuteState) -> (any OutputMuteObservation)? { watch }
    func setMuted(_ muted: Bool, on state: OutputMuteState) -> Bool {
        writes.append(muted)
        guard succeeds else { return false }
        let changed = OutputMuteState(deviceID: state.deviceID, uid: state.uid, muted: muted, writable: state.writable)
        if self.state?.deviceID == state.deviceID { self.state = changed }
        else { otherDevices[state.deviceID] = changed }
        return true
    }
}

@MainActor
struct OutputMuteTests {
    @Test func ownsOnlyItsChangeAndRestoresOnce() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        session.begin(enabled: true)
        session.end()
        session.end()
        #expect(device.writes == [true, false])
        #expect(device.watch.stopped)
    }

    @Test func disabledDoesNothing() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: false)
        session.end()
        #expect(device.writes.isEmpty)
    }

    @Test(arguments: [
        OutputMuteState(deviceID: 42, uid: "speaker", muted: true, writable: true),
        OutputMuteState(deviceID: 42, uid: "speaker", muted: false, writable: false)
    ])
    func leavesPreexistingMuteAndUnsupportedDeviceAlone(state: OutputMuteState) {
        let device = FakeMuteDevice()
        device.state = state
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        session.end()
        #expect(device.writes.isEmpty)
    }

    @Test func writeFailureNeverAcquiresOwnership() {
        let device = FakeMuteDevice()
        device.succeeds = false
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        session.end()
        #expect(device.writes == [true])
        #expect(device.watch.stopped)
    }

    @Test func manualUnmuteAndRemuteRelinquishesOwnership() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.watch.wasInterrupted = true
        session.end()
        #expect(device.writes == [true])
    }

    @Test func changedUIDDespiteReusedDeviceIDDoesNotRestore() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.state = OutputMuteState(deviceID: 42, uid: "different", muted: true, writable: true)
        session.end()
        #expect(device.writes == [true])
    }

    @Test func disconnectedDeviceDoesNotRestore() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.state = nil
        session.end()
        #expect(device.writes == [true])
    }

    @Test func transientReadFailureRetainsOwnershipUntilBoundedRestore() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.readFailures = 1
        #expect(session.end())
        #expect(device.writes == [true, false])
    }

    @Test func failedRestoreReportsFailureAndDoesNotRetryLater() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.succeeds = false
        #expect(!session.end())
        #expect(device.writes == [true, false, false])
        #expect(session.end())
        #expect(device.writes.count == 3)
    }

    @Test func unreadableRestoreReportsFailure() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.readFailures = 2
        #expect(!session.end())
        #expect(device.writes == [true])
    }


    @Test func changingDefaultRestoresOnlyOwnedDevice() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.otherDevices[42] = device.state
        let newOutput = OutputMuteState(deviceID: 43, uid: "headphones", muted: true, writable: true)
        device.state = newOutput
        #expect(session.end())
        #expect(device.state == newOutput)
        #expect(device.otherDevices[42]?.muted == false)
        #expect(device.writes == [true, false])
    }

    @Test func manualChangeOnOldOutputStillWinsAfterDefaultChanges() {
        let device = FakeMuteDevice()
        let session = OutputMuteSession(device: device)
        session.begin(enabled: true)
        device.otherDevices[42] = device.state
        device.state = OutputMuteState(deviceID: 43, uid: "headphones", muted: false, writable: true)
        device.watch.wasInterrupted = true
        #expect(session.end())
        #expect(device.otherDevices[42]?.muted == true)
        #expect(device.writes == [true])
    }

}
