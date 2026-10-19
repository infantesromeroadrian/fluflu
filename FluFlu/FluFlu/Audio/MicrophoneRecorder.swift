import AVFoundation
import CoreMedia
import OSLog

/// Captura un micrófono concreto con AVCaptureSession y vuelca cada buffer en el ingress.
/// Se usa AVCaptureSession y no AVAudioEngine porque este último, en macOS, sigue siempre la
/// entrada por defecto del sistema y descarta el dispositivo que se le fija.
@MainActor
final class MicrophoneRecorder {
    private static let log = AppLog(category: "audio")

    private var session: AVCaptureSession?
    private var sink: CaptureAudioSink?
    private let queue = DispatchQueue(label: "com.adrianinfantes.FluFlu.audio-capture")
    private(set) var ingress = AudioIngress()

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// `deviceUID` vacío o nil usa la entrada por defecto del sistema. Si el elegido ya no está
    /// conectado, se avisa y se sigue con el predeterminado.
    func start(deviceUID: String?) throws {
        var device: AVCaptureDevice?
        if let deviceUID, !deviceUID.isEmpty {
            device = AVCaptureDevice(uniqueID: deviceUID)
            if device == nil { Self.log.warning("input device \(deviceUID) not found; using system default") }
        }
        guard let device = device ?? AVCaptureDevice.default(for: .audio) else { throw DictationFailure.audioEngine }

        let ingress = AudioIngress()
        let session = AVCaptureSession()
        let sink = CaptureAudioSink(ingress: ingress)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(sink, queue: queue)
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { throw DictationFailure.audioEngine }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            Self.log.error("cannot open input device: \(String(describing: error))")
            throw DictationFailure.audioEngine
        }
        // `startRunning()` bloquea cientos de milisegundos en frío. En el hilo principal retrasaba la
        // suelta de la tecla y convertía un toque en "mantener"; por eso arranca en la cola de captura.
        let name = device.localizedName
        let running = RunningSession(session)
        queue.async {
            running.session.startRunning()
            if running.session.isRunning {
                Self.log.info("capturing from \(name)")
            } else {
                Self.log.error("capture session did not start for \(name)")
                ingress.finish()
            }
        }
        self.ingress = ingress
        self.session = session
        self.sink = sink
    }

    /// Cierra la entrada: el ingress termina y el consumidor drena lo que ya estaba encolado.
    /// La parada va a la misma cola serie que el arranque, así nunca lo adelanta.
    func stop() {
        if let session {
            let running = RunningSession(session)
            queue.async { running.session.stopRunning() }
        }
        session = nil
        sink = nil
        ingress.finish()
    }
}

/// AVCaptureSession no es Sendable; se cruza a la cola de captura bajo este envoltorio porque solo
/// esa cola lo arranca y lo para, en orden.
private nonisolated struct RunningSession: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

/// Recibe los sample buffers en la cola de captura y los copia como PCM hacia el ingress.
nonisolated final class CaptureAudioSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let log = AppLog(category: "audio")
    private let ingress: AudioIngress
    private var loggedFormat = false

    init(ingress: AudioIngress) {
        self.ingress = ingress
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard ingress.isAccepting, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        if !loggedFormat {
            loggedFormat = true
            Self.log.info("input format \(format.sampleRate) Hz, \(format.channelCount) ch")
        }
        ingress.yield(pcm)
    }
}
