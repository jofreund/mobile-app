import AVFoundation
import Foundation

/// Fallback path for the rare case where `AVAudioRecorder` ignores the
/// requested settings and hands back e.g. a 48 kHz stereo file: converts a
/// recording to ``IntercomAudioFormat``, so what is streamed is always mono
/// 16-bit at the rate the start message announces.
enum WAVConverter {
    enum ConversionError: Error {
        case unsupportedFormat
    }

    static func convertToRecordingFormat(_ source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(IntercomAudioFormat.sampleRate),
            channels: AVAudioChannelCount(IntercomAudioFormat.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
            throw ConversionError.unsupportedFormat
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("intercom-\(UUID().uuidString)-converted.wav")
        let output = try AVAudioFile(
            forWriting: destination,
            settings: IntercomAudioFormat.recorderSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let frameCapacity: AVAudioFrameCount = 4096
        var reachedEnd = false

        while !reachedEnd {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frameCapacity) else {
                throw ConversionError.unsupportedFormat
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: packetCount
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inputBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
            if status == .endOfStream || status == .error {
                reachedEnd = true
            }
        }

        return destination
    }
}
