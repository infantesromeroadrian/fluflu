import CoreAudio
import Foundation

@MainActor
final class CoreAudioOutputMute: OutputMuteDevice {
    func currentOutput() -> OutputMuteState? { CoreAudioMuteProperties.currentOutput() }
    func state(of owned: OutputMuteState) -> OutputMuteState? { CoreAudioMuteProperties.state(of: owned.deviceID) }

    func observe(_ state: OutputMuteState) -> (any OutputMuteObservation)? {
        CoreAudioMuteObservation.make(state: state)
    }

    func setMuted(_ muted: Bool, on state: OutputMuteState) -> Bool {
        guard let current = self.state(of: state), current.uid == state.uid,
              current.deviceID == state.deviceID, current.writable, current.muted != muted else { return false }
        var address = CoreAudioMuteProperties.muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(state.deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }
}

/// Consultas sin estado; también se usan en la cola de notificaciones para observar el valor
/// antes de saltar al actor principal, donde podrían acumularse varios cambios del usuario.
private nonisolated enum CoreAudioMuteProperties {
    static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    static var defaultAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func currentOutput() -> OutputMuteState? {
        var address = defaultAddress
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return state(of: device)
    }

    static func state(of device: AudioDeviceID) -> OutputMuteState? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        let deviceUID = uid.takeRetainedValue() as String
        address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &writable) == noErr else { return nil }
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: mute))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr else { return nil }
        return OutputMuteState(deviceID: device, uid: deviceUID, muted: mute != 0, writable: writable.boolValue)
    }
}

/// CoreAudio notifica de forma asíncrona y no identifica al escritor. Solo la primera
/// notificación que confirma nuestro mute se reconoce como propia; cualquier otra cede el control.
/// Cambios coalescidos por el driver no son distinguibles: la restauración sigue siendo best-effort.
private nonisolated final class CoreAudioMuteObservation: @unchecked Sendable, OutputMuteObservation {
    private let state: OutputMuteState
    private let queue = DispatchQueue(label: "com.adrianinfantes.FluFlu.output-mute")
    // Acceso exclusivamente en queue. Las referencias de listeners se gestionan en MainActor.
    private var acknowledgedWrite = false
    private var interrupted = false
    @MainActor private var muteListener: AudioObjectPropertyListenerBlock?

    private init(state: OutputMuteState) { self.state = state }

    @MainActor static func make(state: OutputMuteState) -> CoreAudioMuteObservation? {
        let watch = CoreAudioMuteObservation(state: state)
        let mute: AudioObjectPropertyListenerBlock = { [weak watch] _, _ in
            guard let watch else { return }
            let current = CoreAudioMuteProperties.state(of: state.deviceID)
            if !watch.acknowledgedWrite, current?.uid == state.uid, current?.muted == true {
                watch.acknowledgedWrite = true
            } else { watch.interrupted = true }
        }
        var muteAddress = CoreAudioMuteProperties.muteAddress
        guard AudioObjectAddPropertyListenerBlock(state.deviceID, &muteAddress, watch.queue, mute) == noErr else { return nil }
        watch.muteListener = mute
        return watch
    }

    @MainActor var wasInterrupted: Bool { queue.sync { interrupted } }

    @MainActor func stop() {
        if let muteListener {
            var address = CoreAudioMuteProperties.muteAddress
            AudioObjectRemovePropertyListenerBlock(state.deviceID, &address, queue, muteListener)
        }
        muteListener = nil
    }
}
