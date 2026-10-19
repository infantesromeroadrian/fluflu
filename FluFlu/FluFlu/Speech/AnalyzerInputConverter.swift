import AVFoundation
import Speech

/// Adapta los buffers del micrófono al formato que el analizador declara como óptimo.
nonisolated final class AnalyzerInputConverter {
    enum Failure: Error { case unsupportedFormat, conversion }

    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    static func converter(compatibleWith modules: [any SpeechModule]) async throws -> AnalyzerInputConverter {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw Failure.unsupportedFormat
        }
        return AnalyzerInputConverter(outputFormat: format)
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AnalyzerInput {
        if buffer.format == outputFormat { return AnalyzerInput(buffer: buffer) }
        if converter == nil || converter?.inputFormat != buffer.format {
            guard let fresh = AVAudioConverter(from: buffer.format, to: outputFormat) else { throw Failure.unsupportedFormat }
            fresh.primeMethod = .none
            converter = fresh
        }
        guard let converter else { throw Failure.conversion }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw Failure.conversion }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else { throw Failure.conversion }
        return AnalyzerInput(buffer: output)
    }
}
