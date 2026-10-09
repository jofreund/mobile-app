import Foundation

/// Minimal RIFF/WAVE header reader.
///
/// Used to verify that what `AVAudioRecorder` actually produced is what the
/// tab asked for (see ``IntercomAudioFormat``) — iOS can quietly negotiate a
/// different rate — and to hand the `data` chunk to the live-announcement
/// socket, which takes raw PCM and is told the rate separately.
struct WAVFormat: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let bitDepth: Int
    /// Size of the `data` chunk in bytes, as the app will actually send it.
    let dataBytes: Int

    var matchesRecordingFormat: Bool {
        sampleRate == IntercomAudioFormat.sampleRate
            && channels == IntercomAudioFormat.channels
            && bitDepth == IntercomAudioFormat.bitDepth
    }

    var duration: TimeInterval {
        let bytesPerFrame = max(1, channels * bitDepth / 8)
        return Double(dataBytes) / Double(bytesPerFrame * max(1, sampleRate))
    }

    var description: String {
        "\(sampleRate) Hz, \(channels) ch, \(bitDepth) bit, \(dataBytes) B"
    }
}

enum WAVFile {
    /// Where the payload of the `data` chunk sits, and what the header claims
    /// its length is.
    struct DataChunk: Equatable {
        /// Offset of the chunk's 4-byte size field.
        let sizeFieldOffset: Int
        /// Offset of the first audio byte.
        let bodyOffset: Int
        /// Length as written in the header — 0 on a file that was never
        /// finalised.
        let declaredSize: Int
        /// Bytes actually present in the file after ``bodyOffset``.
        let availableSize: Int

        /// The header under-reports the payload, so a strict reader would see
        /// fewer frames than the file holds — zero, in the worst case.
        var isTruncated: Bool {
            declaredSize == 0 || declaredSize > availableSize
        }

        var effectiveSize: Int {
            isTruncated ? availableSize : declaredSize
        }
    }

    static func format(of url: URL) throws -> WAVFormat? {
        // The header lives in the first few hundred bytes; mapping avoids
        // pulling a whole recording into memory.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return parse(data)
    }

    static func parse(_ data: Data) -> WAVFormat? {
        guard isWAV(data) else { return nil }

        var sampleRate = 0
        var channels = 0
        var bitDepth = 0
        var sawFormat = false

        walkChunks(data) { id, body, _ in
            if id == "fmt ", body + 16 <= data.count {
                channels = Int(uint16(data, at: body + 2))
                sampleRate = Int(uint32(data, at: body + 4))
                bitDepth = Int(uint16(data, at: body + 14))
                sawFormat = true
            }
            return true
        }

        guard sawFormat, sampleRate > 0, channels > 0, bitDepth > 0 else { return nil }
        let dataBytes = dataChunk(in: data)?.effectiveSize ?? 0
        return WAVFormat(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth, dataBytes: dataBytes)
    }

    static func dataChunk(in data: Data) -> DataChunk? {
        guard isWAV(data) else { return nil }
        var found: DataChunk?

        walkChunks(data) { id, body, size in
            guard id == "data" else { return true }
            found = DataChunk(
                sizeFieldOffset: body - 4,
                bodyOffset: body,
                declaredSize: size,
                availableSize: max(0, data.count - body)
            )
            return false
        }
        return found
    }

    /// Rewrites the RIFF and `data` chunk sizes when the header under-reports
    /// the payload.
    ///
    /// `AVAudioRecorder` patches those two fields while it closes the file, so
    /// a recording read too early can carry a valid, correctly-formatted header
    /// with a zero-length `data` chunk — which ``pcmData(of:)`` would read as
    /// no audio at all, and the announcement would be the chime alone.
    ///
    /// - Returns: whether the file had to be repaired.
    @discardableResult
    static func repairSizesIfNeeded(at url: URL) throws -> Bool {
        var data = try Data(contentsOf: url)
        guard let chunk = dataChunk(in: data), chunk.isTruncated, chunk.availableSize > 0 else {
            return false
        }

        writeUInt32(&data, at: chunk.sizeFieldOffset, value: chunk.availableSize)
        writeUInt32(&data, at: 4, value: max(0, data.count - 8)) // RIFF size
        try data.write(to: url, options: .atomic)
        return true
    }

    /// The recording itself: the payload of the `data` chunk, which is what the
    /// live-announcement socket takes as raw PCM frames. Trimmed to whole
    /// 16-bit samples. `nil` when the file is not a WAV.
    static func pcmData(of url: URL) throws -> Data? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let chunk = dataChunk(in: data) else { return nil }
        let start = chunk.bodyOffset
        var end = min(data.count, start + chunk.effectiveSize)
        end -= (end - start) % 2
        guard end > start else { return Data() }
        return data.subdata(in: start..<end)
    }

    /// Largest absolute sample value, for 16-bit PCM only; `nil` when the file
    /// is not in a format this can read.
    ///
    /// A peak of exactly zero means the microphone delivered digital silence —
    /// worth telling the user about, because it is indistinguishable from a
    /// successful send once it reaches the speaker.
    static func peakAmplitude(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let format = parse(data),
              format.bitDepth == 16,
              let chunk = dataChunk(in: data),
              chunk.effectiveSize >= 2
        else { return nil }

        let start = chunk.bodyOffset
        let end = min(data.count, start + chunk.effectiveSize)
        var peak = 0

        data.withUnsafeBytes { raw in
            var offset = start
            while offset + 1 < end {
                let bits = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                let sample = Int16(bitPattern: bits)
                // `abs(Int16.min)` overflows, so clamp it.
                peak = max(peak, sample == Int16.min ? Int(Int16.max) : abs(Int(sample)))
                offset += 2
            }
        }
        return peak
    }

    // MARK: - Chunk walking

    private static func isWAV(_ data: Data) -> Bool {
        data.count >= IntercomAudioFormat.minimumWAVBytes
            && ascii(data, at: 0, count: 4) == "RIFF"
            && ascii(data, at: 8, count: 4) == "WAVE"
    }

    /// Visits every chunk after the 12-byte RIFF header. The visitor returns
    /// `false` to stop early.
    private static func walkChunks(_ data: Data, _ visit: (String, Int, Int) -> Bool) {
        var offset = 12
        while offset + 8 <= data.count {
            let id = ascii(data, at: offset, count: 4)
            let size = Int(uint32(data, at: offset + 4))
            let body = offset + 8

            if !visit(id, body, size) { return }

            // A zero size means the writer never finalised this chunk; there is
            // nothing meaningful after it.
            guard size > 0 else { return }
            offset = body + size + (size % 2) // chunks are word-aligned
        }
    }

    // MARK: - Byte helpers

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let start = data.index(data.startIndex, offsetBy: offset)
        return UInt16(data[start]) | (UInt16(data[data.index(after: start)]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            let index = data.index(data.startIndex, offsetBy: offset + i)
            value = (value << 8) | UInt32(data[index])
        }
        return value
    }

    private static func writeUInt32(_ data: inout Data, at offset: Int, value: Int) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        let little = UInt32(clamping: value).littleEndian
        withUnsafeBytes(of: little) { bytes in
            for (i, byte) in bytes.enumerated() {
                data[data.index(data.startIndex, offsetBy: offset + i)] = byte
            }
        }
    }
}
