import AVFoundation

/// What the intercom tab records: linear PCM, mono, 16-bit, in a WAV file whose `data` chunk is
/// handed to Kotlin and streamed as raw frames over the live-announcement socket.
///
/// home-intercom recorded at exactly 16 kHz because Home Assistant only prepends its chime to a
/// clip in the chime's own format. Music Assistant renders announcements itself and takes
/// anything from 8 to 96 kHz, so the rate is chosen for speech instead: 24 kHz carries the
/// whole speech band at half the upload of the hardware's 48 kHz.
enum IntercomAudioFormat {
    static let sampleRate = 24_000
    static let channels = 1
    static let bitDepth = 16
    /// A RIFF header and nothing after it; anything shorter is not a recording.
    static let minimumWAVBytes = 44

    /// Computed rather than stored so it stays usable from any isolation domain
    /// (`[String: Any]` is not `Sendable`).
    static var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}
