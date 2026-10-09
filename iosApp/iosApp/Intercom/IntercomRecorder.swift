import AVFoundation
import Foundation
import Observation
import OSLog

/// Press-and-hold voice recording into a WAV in ``IntercomAudioFormat`` —
/// home-intercom's `AudioRecorder`, unchanged in behaviour. The intercom tab
/// records locally and sends on release, so everything this type learned about
/// warm-up, finalisation, silence and interruptions still applies.
///
/// Owns the recorders and the flow. Only the plain `AVAudioSession` calls
/// (category, activation) go through ``IntercomAudioSession`` to run off the main
/// thread; the recorders themselves are created, prepared, started and
/// stopped here, on the main thread, because `AVAudioRecorder` needs an
/// actively-pumped run loop to finalise a recording and deliver its delegate
/// callbacks — a plain background queue never pumps one.
@MainActor
@Observable
final class IntercomRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecorderError: Error, Equatable, LocalizedError {
        case permissionDenied
        case sessionUnavailable
        case notRecording
        case tooShort
        case silent

        var errorDescription: String? {
            switch self {
            case .permissionDenied: String(localized: "intercom_error_no_microphone")
            case .sessionUnavailable: String(localized: "intercom_error_microphone_unavailable")
            case .notRecording: String(localized: "intercom_error_not_recording")
            case .tooShort: String(localized: "intercom_error_recording_too_short")
            case .silent: String(localized: "intercom_error_recording_silent")
            }
        }
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// The last ``levelHistoryCount`` input levels, 0…1, oldest first — the
    /// waveform in the pop-over draws exactly this. All zeros while nothing is
    /// being recorded.
    ///
    /// The history lives here rather than in the view because it has to
    /// advance on the clock, not on the view's redraws: a level that happens
    /// to repeat is still a new sample, and a waveform fed only by *changed*
    /// values stands still whenever the room goes quiet.
    private(set) var levels: [Double] = IntercomRecorder.silentHistory

    /// Called when the recording had to be aborted from the outside — a phone
    /// call, Siri, or the audio route disappearing.
    @ObservationIgnored var onInterruption: (() -> Void)?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// A recorder that has already opened its file and allocated its buffers,
    /// waiting for the next press — see ``warmUp()``.
    @ObservationIgnored private var prepared: AVAudioRecorder?
    @ObservationIgnored private let engine: IntercomAudioSession
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    /// Resumed from `audioRecorderDidFinishRecording` — see ``stop()``.
    @ObservationIgnored private var finishContinuation: CheckedContinuation<Void, Never>?
    /// A ``warmUp()`` whose session configuration has not come back yet.
    @ObservationIgnored private var isWarmingUp = false
    /// Samples the recorder's meter while it runs — see ``startMetering()``.
    @ObservationIgnored private var meteringTask: Task<Void, Never>?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jofreund.taktgeber", category: "intercom")

    /// How long to wait for the recorder to close its file before reading it
    /// anyway. Finalisation is a header rewrite; it never takes this long.
    static let finalizationTimeout: Duration = .seconds(2)

    /// How often the meter is read — one bar of the waveform per tick.
    static let meteringInterval: Duration = .milliseconds(40)
    /// The quietest level the meter maps to 0. Below roughly -55 dBFS is room
    /// noise, and mapping it would leave the waveform twitching at rest.
    static let meterFloor: Float = -55
    /// The loudest level the meter maps to 1. A phone held at arm's length
    /// averages well below 0 dBFS even when someone speaks up, so full scale is
    /// where normal speech peaks rather than where the format clips.
    static let meterCeiling: Float = -10
    /// How many samples the waveform shows: about a second and a half of
    /// speech at ``meteringInterval``.
    static let levelHistoryCount = 36
    /// How far a sample moves towards a *louder* reading — near 1, so the
    /// waveform answers a syllable in the same frame it starts.
    private static let attack = 0.6
    /// And towards a quieter one. Slower than the attack: a decay that follows
    /// the meter exactly reads as flicker between syllables.
    private static let release = 0.25

    static var silentHistory: [Double] { Array(repeating: 0, count: levelHistoryCount) }

    init(engine: IntercomAudioSession = IntercomAudioSession()) {
        self.engine = engine
        super.init()
        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let prepared {
            prepared.delegate = nil
            try? FileManager.default.removeItem(at: prepared.url)
        }
    }

    var permission: AVAudioApplication.recordPermission { engine.permission }

    func requestPermission() async -> Bool {
        await engine.requestPermission()
    }

    /// Elapsed recording time, for the client-side length cap.
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Lifecycle

    /// Gets everything that can be done ahead of a press out of the way: the
    /// session category, and a recorder that has already opened its file.
    ///
    /// Without this, the first press pays for `setCategory`, `setActive` and
    /// the recorder's buffer allocation *after* the card already says "speak" —
    /// which is exactly how the first syllable of an announcement gets lost.
    /// Never prompts: an undetermined permission is left for the first press.
    ///
    /// Returns immediately: the session category is applied off the main
    /// thread, and the (cheap) `prepareToRecord()` call runs on the main
    /// thread once that comes back, ahead of the caller's next frame.
    func warmUp() {
        guard !isRecording, !isWarmingUp, prepared == nil, permission == .granted else { return }
        isWarmingUp = true
        Task { [weak self, engine = self.engine] in
            let configured = await engine.configure()
            guard let self else { return }
            self.isWarmingUp = false
            // The local player has the session: no spare recorder now. The
            // press pays for one, which the pop-over's growth covers anyway.
            guard configured else { return }
            // A press may have started — or finished — while the category was
            // being applied; do not hand it a stale spare recorder.
            guard !self.isRecording, self.prepared == nil else { return }
            guard let recorder = try? AVAudioRecorder(url: Self.makeFileURL(), settings: IntercomAudioFormat.recorderSettings) else {
                return
            }
            // Created here, on the main thread, so its delegate callbacks keep
            // arriving; `prepareToRecord()` stays here too — see ``IntercomAudioSession``.
            recorder.delegate = self
            recorder.prepareToRecord()
            guard !self.isRecording, self.prepared == nil else {
                recorder.delegate = nil
                try? FileManager.default.removeItem(at: recorder.url)
                return
            }
            self.prepared = recorder
            // `prepareToRecord()` activates the session implicitly, whatever
            // this method's intent, and an activated `.playAndRecord` session
            // is one that stays activated until something deactivates it —
            // ducking other apps' audio for as long as the grid is up, and
            // silencing the system haptic the next press opens with. Nothing
            // is recording here, so put it back down. `start()` re-activates
            // and re-prepares this recorder anyway (see below), so the spare
            // loses nothing by it.
            if !self.isRecording, self.recorder == nil {
                engine.deactivate()
            }
        }
    }

    /// Throws away a prepared recorder and its (empty) file.
    func discardWarmUp() {
        isWarmingUp = false
        guard let prepared else { return }
        self.prepared = nil
        prepared.delegate = nil
        try? FileManager.default.removeItem(at: prepared.url)
    }

    func start() async throws {
        guard !isRecording else { return }
        // The common case is access granted long ago, and `permission` answers
        // that from the process itself. Going through `requestPermission()`
        // regardless costs two thread hops — off the main actor and back — in
        // front of the first syllable, for an answer already in hand.
        if permission != .granted {
            guard await requestPermission() else { throw RecorderError.permissionDenied }
        }

        do {
            try await engine.activate()
        } catch {
            throw RecorderError.sessionUnavailable
        }

        // Reuses the warmed-up recorder when there is one; otherwise pays for a
        // fresh one here.
        let recorder: AVAudioRecorder
        if let prepared {
            recorder = prepared
            self.prepared = nil
            // `warmUp()` prepared this recorder without an active session —
            // deliberately, so warming up neither ducks other apps' audio nor
            // silences the start haptic — which leaves its input tap bound to
            // whatever hardware format was in effect then. Preparing again
            // now that the session is genuinely active re-derives it; skipping this
            // silently records a WAV with a correct-looking header and zero
            // audio frames, however long the press was held.
            recorder.prepareToRecord()
        } else {
            do {
                recorder = try AVAudioRecorder(url: Self.makeFileURL(), settings: IntercomAudioFormat.recorderSettings)
                recorder.delegate = self
            } catch {
                engine.deactivate()
                throw RecorderError.sessionUnavailable
            }
        }

        // Has to be on before `record()`; the meter reads nothing otherwise.
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            try? FileManager.default.removeItem(at: recorder.url)
            engine.deactivate()
            throw RecorderError.sessionUnavailable
        }

        self.recorder = recorder
        isRecording = true
        startedAt = Date()
        startMetering()
        Self.log.debug("Recording started: recorder.isRecording=\(recorder.isRecording, privacy: .public) file=\(recorder.url.lastPathComponent, privacy: .public)")
    }

    /// The extension decides the container — it must stay `.wav`.
    private static func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intercom-\(UUID().uuidString).wav")
    }

    /// Stops recording and returns a WAV file in ``IntercomAudioFormat``.
    ///
    /// Waits for `AVAudioRecorder` to actually close the file before reading
    /// it: `stop()` only *starts* finalisation, and the RIFF/`data` sizes are
    /// patched as part of it. Reading too early yields a well-formed header
    /// that claims zero audio frames — the chime would play and the message
    /// would not.
    ///
    /// The caller owns the returned file and must delete it after uploading.
    func stop() async throws -> URL {
        guard let recorder else { throw RecorderError.notRecording }
        let url = recorder.url
        isRecording = false
        startedAt = nil
        stopMetering()

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            recorder.stop()
            // Belt and braces: if the delegate never fires, carry on rather
            // than leaving the card stuck in `sending`.
            Task { [weak self] in
                try? await Task.sleep(for: IntercomRecorder.finalizationTimeout)
                self?.resumeFinishContinuation()
            }
        }

        self.recorder = nil
        engine.deactivate()

        // Everything that is left is file work, and it is the one part of
        // this method that has no business being on the main actor — see
        // ``RecordedFile``. Awaiting it hands the main thread back to the
        // pop-over, which at this exact moment is springing back onto its
        // tile.
        return try await RecordedFile.prepareForUpload(url)
    }

    /// Aborts without producing a file.
    func cancel() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        resumeFinishContinuation()
        self.recorder = nil
        isRecording = false
        startedAt = nil
        stopMetering()
        engine.deactivate()
        // This runs in the turn that sends the pop-over back to its tile, so
        // the unlink goes off the main thread with everything else.
        RecordedFile.discard(url)
    }

    // MARK: - Metering

    /// Polls the recorder's meter and appends one smoothed 0…1 sample per tick.
    ///
    /// Runs on the main actor: it reads a single meter and appends to a
    /// 36-element array, which costs nothing next to the recording itself, and
    /// the result is observable state a view draws directly.
    ///
    /// Ticks against an absolute deadline rather than sleeping for a fixed
    /// interval: `Task.sleep(for:)` adds however long the tick itself took to
    /// every wait, so the bars slowly drift apart. A tick that lands late
    /// (busy main actor) moves the next deadline forward instead of trying to
    /// catch up, which would fast-forward the waveform.
    private func startMetering() {
        meteringTask?.cancel()
        levels = Self.silentHistory
        meteringTask = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now.advanced(by: IntercomRecorder.meteringInterval)
            while !Task.isCancelled {
                try? await clock.sleep(until: deadline)
                guard !Task.isCancelled, let self, let recorder = self.recorder, self.isRecording else { return }
                recorder.updateMeters()
                self.append(Self.normalize(recorder.averagePower(forChannel: 0)))
                deadline = max(
                    deadline.advanced(by: IntercomRecorder.meteringInterval),
                    clock.now
                )
            }
        }
    }

    /// Adds one sample, smoothed against the one before it, and drops the
    /// oldest — the whole array changes every tick, so the waveform advances
    /// even while the room is silent.
    private func append(_ sample: Double) {
        let previous = levels.last ?? 0
        let factor = sample > previous ? Self.attack : Self.release
        let smoothed = previous + (sample - previous) * factor
        levels.removeFirst()
        levels.append(smoothed)
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        levels = Self.silentHistory
    }

    /// Maps a dBFS meter reading onto 0…1 between ``meterFloor`` and
    /// ``meterCeiling``. The cube root lifts the quiet end, where speech mostly
    /// lives, so the waveform swings across the height it is given instead of
    /// hugging the baseline.
    static func normalize(_ decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let clamped = min(max(decibels, meterFloor), meterCeiling)
        let linear = (clamped - meterFloor) / (meterCeiling - meterFloor)
        return Double(cbrt(linear))
    }

    // MARK: - Finalisation

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.resumeFinishContinuation()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.resumeFinishContinuation()
        }
    }

    /// Resumes at most once, whichever of delegate callback, timeout or cancel
    /// gets there first.
    private func resumeFinishContinuation() {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume()
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self.cancel()
                self.onInterruption?()
            }
        }
    }
}

/// The file work that follows a recording the recorder has closed: repairing
/// a header that finalisation did not patch, checking what was actually
/// captured, and converting it when iOS ignored the requested format.
///
/// Deliberately its own type rather than a method on ``IntercomRecorder``. That
/// class is `@MainActor` because `AVAudioRecorder` needs an actively-pumped
/// run loop — and none of the work here touches `AVAudioRecorder` at all. It
/// is a full read and rewrite of the header, a mapped read of the whole
/// recording, a sample-by-sample scan of every frame in it and, in the bad
/// case, a complete resample: whole milliseconds, growing with the length of
/// the press. On the main actor all of that landed in the frame where the
/// pop-over starts springing back onto its tile, which is exactly where the
/// hitch was.
///
/// These are `async` methods on a type with no isolation of its own, so they
/// run on the generic executor however they are called.
enum RecordedFile {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jofreund.taktgeber", category: "intercom")

    /// Makes a just-closed recording ready to upload, or says why it is not
    /// worth uploading.
    ///
    /// The returned URL may be a converted copy, in which case the original
    /// is already deleted. A throw takes the file with it.
    static func prepareForUpload(_ url: URL) async throws -> URL {
        // Repairs the header if finalisation still did not land.
        if (try? WAVFile.repairSizesIfNeeded(at: url)) == true {
            log.warning("WAV header was not finalised; sizes repaired before upload")
        }

        guard let format = try? WAVFile.format(of: url), format.dataBytes > 0 else {
            let onDiskBytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            let parsedFormat = try? WAVFile.format(of: url)
            log.error("tooShort diagnostics: onDiskBytes=\(onDiskBytes ?? -1, privacy: .public) parsed=\(parsedFormat?.description ?? "nil", privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            throw IntercomRecorder.RecorderError.tooShort
        }

        let peak = WAVFile.peakAmplitude(at: url)
        log.debug("Recorded \(format.description, privacy: .public), peak \(peak ?? -1, privacy: .public)")

        // Digital silence reaches the speaker as a successful, inaudible
        // announcement — say so instead.
        if peak == 0 {
            try? FileManager.default.removeItem(at: url)
            throw IntercomRecorder.RecorderError.silent
        }

        // Verify what was actually written; iOS can silently negotiate a
        // different hardware rate.
        if !format.matchesRecordingFormat {
            log.warning("Recorder produced \(format.description, privacy: .public); converting")
            if let converted = try? WAVConverter.convertToRecordingFormat(url) {
                try? FileManager.default.removeItem(at: url)
                return converted
            }
        }
        return url
    }

    /// Deletes a recording nobody wants any more, off whatever thread the
    /// caller is on. Nothing waits for it.
    static func discard(_ url: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
