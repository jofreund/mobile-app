import AVFoundation
import XCTest

/// The intercom recording's WAV handling, ported with home-intercom's
/// `WAVFormatTests`, plus the data-chunk read that hands the audio to the
/// live-announcement socket.
final class IntercomWAVFileTests: XCTestCase {
    /// The settings handed to `AVAudioRecorder` must produce the mono 16-bit
    /// WAV the start message announces; the socket takes the samples raw.
    func testRecorderSettingsProduceTheRecordingFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-settings-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(
            forWriting: url,
            settings: IntercomAudioFormat.recorderSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(IntercomAudioFormat.sampleRate),
            channels: 1,
            interleaved: true
        ))
        let frames = AVAudioFrameCount(IntercomAudioFormat.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)

        let parsed = try XCTUnwrap(WAVFile.format(of: url))
        XCTAssertEqual(parsed.sampleRate, IntercomAudioFormat.sampleRate)
        XCTAssertEqual(parsed.channels, 1)
        XCTAssertEqual(parsed.bitDepth, 16)
        XCTAssertTrue(parsed.matchesRecordingFormat)
        XCTAssertEqual(parsed.duration, 1.0, accuracy: 0.01)
    }

    func testParsesSyntheticHeader() {
        let data = Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: 160)
        let format = WAVFile.parse(data)
        XCTAssertEqual(format, WAVFormat(sampleRate: 24_000, channels: 1, bitDepth: 16, dataBytes: 320))
        XCTAssertTrue(format?.matchesRecordingFormat == true)
    }

    func testRejectsMismatchedFormats() {
        let stereo = WAVFile.parse(Self.makeWAV(sampleRate: 24_000, channels: 2, bitDepth: 16, frames: 10))
        XCTAssertFalse(stereo?.matchesRecordingFormat == true)

        let fortyEight = WAVFile.parse(Self.makeWAV(sampleRate: 48_000, channels: 1, bitDepth: 16, frames: 10))
        XCTAssertFalse(fortyEight?.matchesRecordingFormat == true)
    }

    func testRejectsNonWAVData() {
        XCTAssertNil(WAVFile.parse(Data(repeating: 0, count: 100)))
        XCTAssertNil(WAVFile.parse(Data("RIFF".utf8)))
    }

    /// A header and nothing after it is exactly 44 bytes.
    func testMinimumSizeIsABareHeader() {
        XCTAssertEqual(IntercomAudioFormat.minimumWAVBytes, 44)
        XCTAssertEqual(Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: 0).count, 44)
    }

    // MARK: - The audio for the socket

    /// What goes to the server is the samples and nothing else: no header.
    func testPCMDataIsTheDataChunkAlone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples: [Int16] = [1, -2, 300, Int16.max]
        try Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: samples.count, samples: samples)
            .write(to: url)

        let pcm = try XCTUnwrap(WAVFile.pcmData(of: url))
        XCTAssertEqual(pcm.count, samples.count * 2)
        let decoded = stride(from: 0, to: pcm.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(pcm[offset]) | (UInt16(pcm[offset + 1]) << 8))
        }
        XCTAssertEqual(decoded, samples)
    }

    /// An unfinalised header still yields the audio the file holds.
    func testPCMDataReadsPastAHeaderThatClaimsNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-unfinalised-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: 100, declaredDataSize: 0)
            .write(to: url)

        XCTAssertEqual(try WAVFile.pcmData(of: url)?.count, 200)
    }

    func testPCMDataIsNilForSomethingElse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 7, count: 100).write(to: url)
        XCTAssertNil(try WAVFile.pcmData(of: url))
    }

    // MARK: - Unfinalised headers

    /// `AVAudioRecorder` patches the RIFF and `data` sizes while it closes the
    /// file. A recording read before that lands claims zero audio frames, so
    /// the announcement would play as chime-then-silence.
    func testRepairsHeaderThatClaimsZeroFrames() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfinalised-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let broken = Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: 800, declaredDataSize: 0)
        try broken.write(to: url)

        let chunkBefore = try XCTUnwrap(WAVFile.dataChunk(in: broken))
        XCTAssertEqual(chunkBefore.declaredSize, 0)
        XCTAssertTrue(chunkBefore.isTruncated)

        XCTAssertTrue(try WAVFile.repairSizesIfNeeded(at: url))

        let repaired = try Data(contentsOf: url)
        let chunkAfter = try XCTUnwrap(WAVFile.dataChunk(in: repaired))
        XCTAssertEqual(chunkAfter.declaredSize, 1_600)
        XCTAssertFalse(chunkAfter.isTruncated)
        XCTAssertEqual(WAVFile.parse(repaired)?.dataBytes, 1_600)
        // RIFF size is patched too.
        XCTAssertEqual(repaired.count, 1_600 + 44)
    }

    func testRepairLeavesIntactFilesAlone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intact-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: 100).write(to: url)
        XCTAssertFalse(try WAVFile.repairSizesIfNeeded(at: url))
    }

    // MARK: - Silence detection

    func testPeakAmplitudeIsZeroForDigitalSilence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try Self.makeWAV(sampleRate: 24_000, channels: 1, bitDepth: 16, frames: 200).write(to: url)
        XCTAssertEqual(WAVFile.peakAmplitude(at: url), 0)
    }

    func testPeakAmplitudeFindsLoudestSample() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples: [Int16] = [0, 120, -4_096, 31, Int16.min, 7]
        let data = Self.makeWAV(
            sampleRate: 24_000,
            channels: 1,
            bitDepth: 16,
            frames: samples.count,
            samples: samples
        )
        try data.write(to: url)

        // `Int16.min` clamps to `Int16.max` rather than overflowing.
        XCTAssertEqual(WAVFile.peakAmplitude(at: url), Int(Int16.max))
    }

    // MARK: - Fixture

    static func makeWAV(
        sampleRate: Int,
        channels: Int,
        bitDepth: Int,
        frames: Int,
        declaredDataSize: Int? = nil,
        samples: [Int16] = []
    ) -> Data {
        let blockAlign = channels * bitDepth / 8
        let dataBytes = frames * blockAlign
        var data = Data()

        func append32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(channels)
        append32(sampleRate)
        append32(sampleRate * blockAlign)
        append16(blockAlign)
        append16(bitDepth)
        data.append(contentsOf: Array("data".utf8))
        append32(declaredDataSize ?? dataBytes)
        if samples.isEmpty {
            data.append(Data(repeating: 0, count: dataBytes))
        } else {
            for sample in samples { append16(Int(UInt16(bitPattern: sample))) }
        }
        return data
    }
}
