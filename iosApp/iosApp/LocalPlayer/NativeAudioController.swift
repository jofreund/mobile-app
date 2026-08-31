import Foundation
import AVFoundation
import AudioToolbox
import MusicAssistantKit

/// Native iOS audio player using AudioQueue
/// Replaces MPVController for better iOS integration
class NativeAudioController: NSObject, PlatformAudioPlayer {

    // MARK: - AudioQueue
    private var audioQueue: AudioQueueRef?
    private var audioFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()

    // MARK: - Audio Buffer

    /// Decoded PCM waiting for the AudioQueue, as one contiguous byte run rather than a
    /// list of decoder chunks. A chunk larger than one queue buffer used to be silently
    /// truncated by the copy, and a smaller one left the rest of the buffer unused.
    private var pendingPCM = Data()
    private let bufferLock = NSLock()

    /// Buffers the queue handed back while no PCM was ready. They are parked here and
    /// re-enqueued once audio arrives. Filling them with silence instead — what this used
    /// to do — makes every underrun permanent: the silence plays out, so real audio ends
    /// up one whole buffer further behind, for good.
    private var idleBuffers: [AudioQueueBufferRef] = []

    private let kNumberOfBuffers = 5
    /// Milliseconds of audio per queue buffer. A buffer is the granularity of an underrun,
    /// and the previous fixed 64 KB meant ~350 ms of damage per miss at CD rate.
    private let kBufferMillis = 30
    /// Milliseconds of PCM to collect before starting the queue. Replaces priming with
    /// silence, which prepended ~1.4 s (4 × 64 KB at CD rate) to every start and — since
    /// `pauseSink` tears the queue down — to every resume.
    private let kPrimeMillis = 60
    /// Start anyway if the stream never reaches [kPrimeMillis], so a short tail or a
    /// stalling server can't leave audio stranded in the staging buffer.
    private let kPrimeTimeoutSeconds = 0.2
    private var primeTimerScheduled = false


    // MARK: - Decoder
    private var decoder: NativeAudioDecoder?
    private let decoderLock = NSLock()
    private var listener: MediaPlayerListener?

    // MARK: - Stream Configuration
    private var currentCodec: String = "flac"
    private var currentSampleRate: Int32 = 48000
    private var currentChannels: Int32 = 2
    private var currentBitDepth: Int32 = 16
    private var codecHeader: Data?

    // MARK: - State
    private var isPlaying = false
    /// True while local playback owns or is claiming the shared audio session.
    var isRenderingAudio: Bool { streamStarted || isPlaying }
    private var streamStarted = false
    // Play-intent gate (mirrors Android's shouldPlayAudio). While false — paused or
    // interrupted — incoming audio is dropped instead of (re)starting the queue, so
    // a packet still in the consumer pipeline can't undo an optimistic pause.
    private var shouldPlay = true
    // True only while we hold a server pause issued in response to an audio-session
    // interruption (phone call, Siri). On .ended we auto-resume the server only if
    // this is set — so we never spontaneously start playback that the user didn't
    // have running before the interruption.
    private var pausedByInterruption = false

    // MARK: - Format Arithmetic

    /// FLAC always decodes to Int32, and 24-bit PCM is unpacked to Int32 by
    /// `PCMPassthroughDecoder`. Everything else keeps the negotiated depth.
    private var effectiveBitDepth: Int32 {
        (currentCodec == "flac" || currentBitDepth == 24) ? 32 : currentBitDepth
    }

    private var bytesPerFrame: Int {
        max(1, Int(currentChannels) * Int(effectiveBitDepth / 8))
    }

    /// Whole frames only — a partial frame would shift the channel interleave.
    private func byteCount(forMillis millis: Int) -> Int {
        let raw = Int(currentSampleRate) * bytesPerFrame * millis / 1000
        return max(bytesPerFrame, (raw / bytesPerFrame) * bytesPerFrame)
    }

    // MARK: - Logging
    // Routes through Kermit (NativeLog) so these reach the shareable in-memory buffer
    // and os.Logger
    private static let logTag = "NativeAudioController"
    private func logInfo(_ message: String) { NativeLog.shared.info(tag: Self.logTag, message: message) }
    private func logError(_ message: String) { NativeLog.shared.error(tag: Self.logTag, message: message) }
    private func logDebug(_ message: String) { NativeLog.shared.debug(tag: Self.logTag, message: message) }

    override init() {
        super.init()
        logDebug("Initialized")

        // Handle audio session interruptions (phone calls, Siri, alarms)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        // Handle route changes (headphones unplugged, Bluetooth disconnects)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // System auto-pauses AudioQueue. Tell the server to pause too so playback
            // resumes from the same position afterwards instead of skipping ahead while
            // the call held the audio session.
            logInfo("Audio session interrupted")
            if isPlaying {
                pausedByInterruption = true
                logInfo("Pausing server playback due to interruption")
                remoteCommandHandler?.onCommand(command: "pause", source: "interruption")
            }
        case .ended:
            guard pausedByInterruption else { break }
            pausedByInterruption = false
            // We deliberately do not use .shouldResume here as it is not guaranteed
            // to be set even in cases it should be. As per Apple, it's a hint not
            // a contract. Instead we track for ourselves if we were interrupted,
            // and once control is handed back, if another app is now using the
            // audio device exclusively.
            if !AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint {
                logInfo("Resuming server playback after interruption")
                remoteCommandHandler?.onCommand(command: "play", source: "interruption")
            } else {
                logInfo("Another app holds audio — staying paused")
            }
        @unknown default:
            break
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            logInfo("Audio output device disconnected")
            let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            handleOldDeviceUnavailable(previousRoute: previousRoute)
        }
    }

    /// Pause when the active output route disappears (Bluetooth disconnect,
    /// headphones unplug, AirPods power-off, CarPlay disconnect) — never let
    /// playback silently fall back to the phone speaker. Shutting `shouldPlay`
    /// drops in-flight packets so the next one can't rebuild the queue on the
    /// new route; the server pause stops the stream at the source. Unlike an
    /// interruption, iOS sends no matching `.ended`, so this is a deliberate
    /// pause the user resumes by hand, on whatever route is then active.
    /// (AirPods already send their own `pause` remote command on removal; the
    /// `streamStarted` guard makes this a no-op once that has shut the gate.)
    private func handleOldDeviceUnavailable(previousRoute: AVAudioSessionRouteDescription?) {
        guard streamStarted else { return }
        let prev = previousRoute?.outputs.first?.portType.rawValue ?? "unknown"
        logInfo("\(prev) disappeared — pausing playback")
        shouldPlay = false
        streamStarted = false
        stopAudioQueue()
        remoteCommandHandler?.onCommand(command: "pause", source: "route_loss")
    }

    // MARK: - PlatformAudioPlayer Protocol

    func prepareStream(codec: String, sampleRate: Int32, channels: Int32, bitDepth: Int32, codecHeader: String?, listener: MediaPlayerListener) {
        logInfo("prepareStream - codec=\(codec), rate=\(sampleRate), ch=\(channels), bit=\(bitDepth)")

        self.listener = listener
        self.currentCodec = codec.lowercased()
        self.currentSampleRate = sampleRate
        self.currentChannels = channels
        self.currentBitDepth = bitDepth
        self.streamStarted = false
        self.shouldPlay = true

        // Decode codec header if present
        if let headerBase64 = codecHeader, let headerData = Data(base64Encoded: headerBase64) {
            self.codecHeader = headerData
            logDebug("Decoded codec header: \(headerData.count) bytes")
        } else {
            self.codecHeader = nil
        }

        // Stop any existing playback (also drops staged PCM from the previous format)
        stopAudioQueue()

        // Create decoder for codec
        do {
            let newDecoder = try AudioDecoderFactory.create(
                codec: currentCodec,
                sampleRate: Int(sampleRate),
                channels: Int(channels),
                bitDepth: Int(bitDepth),
                codecHeader: self.codecHeader
            )
            decoderLock.lock()
            decoder = newDecoder
            decoderLock.unlock()
            logInfo("Created decoder for \(codec)")
        } catch {
            logError("Failed to create decoder: \(error)")
            listener.onError(error: KotlinThrowable(message: error.localizedDescription))
            return
        }

        listener.onReady()
    }

    /// Called from Kotlin via efficient NSData bulk-copy path (avoids per-byte Swift interop).
    func writeRawPcmNSData(data: Data) {
        processAudioData(data)
    }

    /// Legacy path: still satisfies the PlatformAudioPlayer protocol but is no longer
    /// called from Kotlin (Kotlin always uses writeRawPcmNSData now).
    func writeRawPcm(data: KotlinByteArray) {
        let size = Int(data.size)
        var swiftData = Data(count: size)
        for i in 0..<size {
            swiftData[i] = UInt8(bitPattern: data.get(index: Int32(i)))
        }
        processAudioData(swiftData)
    }

    private func processAudioData(_ swiftData: Data) {
        // Suspended (paused / interrupted): drop in-flight audio rather than
        // restart the queue, so a packet still in the consumer pipeline can't
        // undo the pause before the server stops streaming.
        guard shouldPlay else { return }

        // Decode before starting the queue, not after: the queue used to be built on the
        // first *packet*, with no PCM ready, so its buffers were primed with silence.
        decoderLock.lock()
        guard let decoder = decoder else {
            decoderLock.unlock()
            logDebug("No decoder available — dropping packet")
            return
        }
        let pcmData: Data
        do {
            pcmData = try decoder.decode(swiftData)
        } catch {
            decoderLock.unlock()
            logDebug("Decode error: \(error)")
            return
        }
        decoderLock.unlock()

        bufferLock.lock()
        pendingPCM.append(pcmData)
        bufferLock.unlock()

        guard streamStarted else {
            startQueueIfPrimed(force: false)
            if !streamStarted { schedulePrimeTimeout() }
            return
        }

        drainIdleBuffers()
    }

    /// The single entry point for starting the queue, so the prime path and its timeout
    /// fallback can never both build one.
    private func startQueueIfPrimed(force: Bool) {
        bufferLock.lock()
        let buffered = pendingPCM.count
        let ready = !streamStarted && buffered > 0 &&
            (force || buffered >= byteCount(forMillis: kPrimeMillis))
        if ready {
            streamStarted = true
            primeTimerScheduled = false
        }
        bufferLock.unlock()

        guard ready else { return }
        logDebug("Priming done (\(buffered) bytes, force=\(force)) — starting queue")
        NowPlayingCoordinator.shared.activatePlayback()
        startAudioQueue()
    }

    /// Arms a one-shot fallback start. Only ever one is in flight; it is disarmed by the
    /// queue starting or by teardown, and it re-checks both before doing anything.
    private func schedulePrimeTimeout() {
        bufferLock.lock()
        let alreadyScheduled = primeTimerScheduled
        primeTimerScheduled = true
        bufferLock.unlock()
        guard !alreadyScheduled else { return }

        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + kPrimeTimeoutSeconds) { [weak self] in
                guard let self = self, self.shouldPlay, !self.streamStarted else { return }
                self.logDebug("Prime timeout — starting queue with what we have")
                self.startQueueIfPrimed(force: true)
            }
    }

    /// Re-enqueue buffers an underrun parked, now that there is audio for them.
    private func drainIdleBuffers() {
        guard let queue = audioQueue else { return }
        while true {
            bufferLock.lock()
            let buffer = (pendingPCM.count >= bytesPerFrame && !idleBuffers.isEmpty)
                ? idleBuffers.removeFirst()
                : nil
            bufferLock.unlock()

            guard let buffer = buffer else { return }
            fillBuffer(queue: queue, buffer: buffer)
        }
    }

    func stopRawPcmStream() {
        logInfo("Stopping stream")
        shouldPlay = false
        streamStarted = false
        stopAudioQueue()
    }

    /// Tear down rather than `AudioQueuePause`: a paused queue replays its stale
    /// primed buffers on resume, then underruns. `shouldPlay = false` drops any
    /// in-flight audio so the consumer can't immediately rebuild the queue;
    /// resume then rebuilds clean on the next packet, like a cold start.
    func pauseSink() {
        logInfo("pauseSink")
        shouldPlay = false
        streamStarted = false
        tearDownQueue()
    }

    /// Reactivating the session reclaims audio from another app that grabbed it.
    /// `shouldPlay = true` re-opens the write gate; the queue rebuilds on the next
    /// audio packet, or is started here if one still exists (gapless restart).
    func resumeSink() {
        logInfo("resumeSink")
        shouldPlay = true
        NowPlayingCoordinator.shared.activatePlayback()
        isPlaying = true
        if let queue = audioQueue {
            AudioQueueStart(queue, nil)
        }
    }

    /// Drop buffered PCM (track transition / playback-delay re-phase).
    func flush() {
        bufferLock.lock()
        pendingPCM.removeAll(keepingCapacity: true)
        bufferLock.unlock()
    }

    func setVolume(volume: Int32) {
        guard let queue = audioQueue else { return }
        let floatVolume = Float(volume) / 100.0
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, floatVolume)
    }

    func setMuted(muted: Bool) {
        guard let queue = audioQueue else { return }
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, muted ? 0.0 : 1.0)
    }

    func dispose() {
        // The Now Playing surface is cleared by the track channel going null
        // (pipeline teardown removes the current item); no direct clear here.
        stopAudioQueue()
        decoderLock.lock()
        decoder = nil
        decoderLock.unlock()
    }

    // MARK: - AudioQueue Management

    private func startAudioQueue() {
        // Configure audio format (always output PCM)
        audioFormat.mSampleRate = Float64(currentSampleRate)
        audioFormat.mFormatID = kAudioFormatLinearPCM
        audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        audioFormat.mFramesPerPacket = 1
        audioFormat.mChannelsPerFrame = UInt32(currentChannels)

        audioFormat.mBitsPerChannel = UInt32(effectiveBitDepth)
        audioFormat.mBytesPerFrame = UInt32(bytesPerFrame)
        audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame

        logDebug("Audio format - \(currentSampleRate)Hz, \(currentChannels)ch, \(effectiveBitDepth)bit")

        // Create AudioQueue
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &audioFormat,
            audioQueueCallback,
            selfPointer,
            nil,
            nil,
            0,
            &queue
        )

        guard status == noErr, let queue = queue else {
            logError("Failed to create AudioQueue: \(status)")
            return
        }

        audioQueue = queue

        // Fill buffers from the PCM staged during priming. `fillBuffer` parks whatever it
        // cannot fill instead of enqueuing silence, so the queue starts with real audio
        // only and `drainIdleBuffers` takes over from the next packet.
        let bufferBytes = UInt32(byteCount(forMillis: kBufferMillis))
        for _ in 0..<kNumberOfBuffers {
            var buffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, bufferBytes, &buffer)

            if allocStatus == noErr, let buffer = buffer {
                fillBuffer(queue: queue, buffer: buffer)
            } else {
                logError("Failed to allocate AudioQueue buffer: \(allocStatus)")
            }
        }

        // Start playback
        let startStatus = AudioQueueStart(queue, nil)
        if startStatus == noErr {
            isPlaying = true
            logInfo("AudioQueue started")
        } else {
            logError("Failed to start AudioQueue: \(startStatus)")
        }
    }

    private func stopAudioQueue() {
        tearDownQueue()
        pausedByInterruption = false // Stream stopped — no auto-resume on .ended.
    }

    /// `AudioQueueStop(_, true)` discards enqueued hardware buffers, so a rebuilt
    /// queue never replays stale audio. Leaves `pausedByInterruption` untouched —
    /// a pause issued during `.began` must still auto-resume on `.ended`.
    private func tearDownQueue() {
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
            isPlaying = false
            logInfo("AudioQueue stopped")
        }

        // Outside the queue check on purpose: `prepareStream` tears down before a queue
        // exists, and staged PCM from the previous format must not survive into the new
        // one. Dispose frees every buffer, parked ones included, so the pointers go too —
        // a rebuilt queue must never be handed a dangling `AudioQueueBufferRef`.
        bufferLock.lock()
        idleBuffers.removeAll()
        pendingPCM.removeAll(keepingCapacity: true)
        primeTimerScheduled = false
        bufferLock.unlock()
    }

    fileprivate func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let frame = bytesPerFrame

        bufferLock.lock()
        let take = (min(capacity, pendingPCM.count) / frame) * frame
        if take > 0 {
            pendingPCM.withUnsafeBytes { srcBytes in
                _ = memcpy(buffer.pointee.mAudioData, srcBytes.baseAddress, take)
            }
            pendingPCM.removeFirst(take)
            // `removeFirst` leaves a non-zero start index behind; resetting once the run is
            // empty keeps the append/drain cycle from dragging a growing offset along.
            if pendingPCM.isEmpty { pendingPCM.removeAll(keepingCapacity: true) }
        } else {
            // Starved. Park the buffer rather than enqueue silence; `drainIdleBuffers`
            // returns it to the queue with the next packet, so a momentary gap costs the
            // gap itself instead of a permanent buffer's worth of added latency.
            idleBuffers.append(buffer)
        }
        bufferLock.unlock()

        guard take > 0 else { return }

        buffer.pointee.mAudioDataByteSize = UInt32(take)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    // MARK: - Now Playing (Control Center / Lock Screen)

    private var remoteCommandHandler: RemoteCommandHandler?

    func setLongFormSeekIntervals(backSeconds: Int64, forwardSeconds: Int64) {
        NowPlayingCoordinator.shared.setLongFormSeekIntervals(
            backSeconds: backSeconds,
            forwardSeconds: forwardSeconds
        )
    }

    func setRemoteCommandHandler(handler: RemoteCommandHandler?) {
        self.remoteCommandHandler = handler

        NowPlayingCoordinator.shared.setCommandHandler { [weak self] command in
            self?.logInfo("Remote command: \(command)")
            self?.remoteCommandHandler?.onCommand(command: command, source: "remote")
        }
    }
}

// MARK: - AudioQueue Callback

private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData = userData else { return }

    let controller = Unmanaged<NativeAudioController>.fromOpaque(userData).takeUnretainedValue()
    controller.fillBuffer(queue: queue, buffer: buffer)
}
