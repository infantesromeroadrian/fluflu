import AVFoundation
import CoreMedia
import OSLog

/// Captura un micrófono concreto con AVCaptureSession y vuelca cada buffer en el ingress.
/// Se usa AVCaptureSession y no AVAudioEngine porque este último, en macOS, sigue siempre la
/// entrada por defecto del sistema y descarta el dispositivo que se le fija.
@MainActor
final class MicrophoneRecorder {
    /// `nonisolated`: también se escribe desde la cola de captura, fuera del actor principal.
    nonisolated private static let log = AppLog(category: "audio")

    private var session: AVCaptureSession?
    private var sink: CaptureAudioSink?
    private let queue = DispatchQueue(label: "com.adrianinfantes.FluFlu.audio-capture")
    private(set) var ingress = AudioIngress()

    /// Con el permiso ya concedido se responde sin pasar por `requestAccess`, que costaba 30–55 ms en
    /// cada pulsación; solo se pregunta al sistema mientras el usuario no ha decidido.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Inicializa la pila de captura (dispositivo, entrada y sesión) sin arrancarla, para que el primer
    /// dictado tras abrir la app no pague ~180 ms antes de abrir el micrófono. No enciende el micrófono
    /// ni el indicador de privacidad, y sin permiso no hace nada para no provocar el diálogo del sistema.
    func prewarm(deviceUID: String?) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let start = ContinuousClock.now
        guard let device = Self.device(for: deviceUID, warn: false), let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        if session.canAddOutput(output) { session.addOutput(output) }
        Self.log.info("capture stack prewarmed in \(Self.milliseconds(ContinuousClock.now - start)) ms")
    }

    private static func device(for deviceUID: String?, warn: Bool) -> AVCaptureDevice? {
        if let deviceUID, !deviceUID.isEmpty {
            if let device = AVCaptureDevice(uniqueID: deviceUID) { return device }
            if warn { log.warning("input device \(deviceUID) not found; using system default") }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// `deviceUID` vacío o nil usa la entrada por defecto del sistema. Si el elegido ya no está
    /// conectado, se avisa y se sigue con el predeterminado.
    func start(deviceUID: String?) throws {
        let setupStart = ContinuousClock.now
        guard let device = Self.device(for: deviceUID, warn: true) else { throw DictationFailure.audioEngine }

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
        let setup = Self.milliseconds(ContinuousClock.now - setupStart)
        queue.async {
            let runStart = ContinuousClock.now
            running.session.startRunning()
            if running.session.isRunning {
                Self.log.info("capturing from \(name) (setup \(setup) ms, start \(Self.milliseconds(ContinuousClock.now - runStart)) ms)")
            } else {
                Self.log.error("capture session did not start for \(name)")
                ingress.finish()
            }
        }
        self.ingress = ingress
        self.session = session
        self.sink = sink
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
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
