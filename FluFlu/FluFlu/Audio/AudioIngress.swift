import AVFoundation

/// Un buffer copiado viaja exactamente una vez desde el callback de tiempo real hasta su consumidor.
nonisolated struct AudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Cola acotada entre el hilo de audio y el pipeline de voz. Si se desborda, deja de admitir:
/// perder audio en silencio produciría transcripciones con huecos imposibles de diagnosticar.
nonisolated final class AudioIngress: @unchecked Sendable {
    static let capacity = 128

    let stream: AsyncStream<AudioPacket>
    private let continuation: AsyncStream<AudioPacket>.Continuation
    private let lock = NSLock()
    private var accepting = true
    private var overflowed = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(Self.capacity))
    }

    @discardableResult
    func yield(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting, let copy = buffer.copied() else { return false }
        switch continuation.yield(AudioPacket(buffer: copy)) {
        case .enqueued:
            return true
        case .dropped:
            overflowed = true; accepting = false; continuation.finish(); return false
        case .terminated:
            accepting = false; return false
        @unknown default:
            accepting = false; continuation.finish(); return false
        }
    }

    func finish() {
        lock.lock(); accepting = false; continuation.finish(); lock.unlock()
    }

    var isAccepting: Bool { lock.lock(); defer { lock.unlock() }; return accepting }
    var didOverflow: Bool { lock.lock(); defer { lock.unlock() }; return overflowed }
}

extension AVAudioPCMBuffer {
    /// El buffer del tap pertenece al motor y se reutiliza: hay que copiarlo antes de cruzar de hilo.
    nonisolated func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            if let sourceData = from.mData, let targetData = to.mData {
                memcpy(targetData, sourceData, Int(from.mDataByteSize))
            }
        }
        return copy
    }

    nonisolated var rmsLevel: Double {
        guard let channels = floatChannelData, frameLength > 0 else { return 0 }
        var squareSum = 0.0
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameLength) {
                let value = Double(channels[channel][frame])
                squareSum += value * value
            }
        }
        return min(1, sqrt(squareSum / Double(frameLength * format.channelCount)))
    }
}
