import AVFoundation
import Foundation

/// The serial queue the explicit `AVAudioSession` calls run on, plus the
/// session state that goes with it.
///
/// This is home-intercom's `AudioEngine` with one change: there, the intercom
/// was the only thing on the shared session; here, the local player is a
/// second one. While it is on, `NowPlayingCoordinator` keeps the session in
/// `.playback` and caches the mode it last set. So instead of setting
/// `.playAndRecord` once per process and leaving it, this type:
///
/// - applies `.playAndRecord` on every press, after noting the category, mode
///   and options it found, and puts exactly those back when the press ends;
/// - never sets a preferred sample rate — that is session-wide and would
///   resample the local player's output (the recorder converts on its own);
/// - only deactivates a session it brought up itself — one that was already
///   live for local playback is left running, or the music would stop;
/// - leaves the session alone for a warm-up while the local player plays:
///   changing the category of an active session moves its route.
///
/// While the local player plays, a press records from the built-in
/// microphone, mixes with that playback and keeps Bluetooth output on A2DP, so
/// the music keeps its route and its quality. Otherwise it is home-intercom's
/// configuration, which also takes a Bluetooth headset's microphone.
///
/// `AVAudioRecorder`'s `prepareToRecord`, `record` and `stop` are deliberately
/// **not** routed through here, even though they implicitly touch the session
/// too and iOS logs the same
///
///     AVAudioSession_iOS.mm  This method can lead to UI unresponsiveness if
///     called on the main thread.
///
/// warning for them. `AVAudioRecorder` needs to be driven from a thread with
/// an actively-pumped run loop — normally the main thread — to reliably
/// finalise a recording and deliver `audioRecorderDidFinishRecording`; a plain
/// `DispatchQueue.async` block runs once and returns without pumping one, so a
/// recorder driven from here silently produces a file with no audio data,
/// however long it was held. Those three calls stay on ``IntercomRecorder``,
/// which is `@MainActor`; only the pure session calls (`configure`,
/// `activate`, `deactivate`) come here.
///
/// `@unchecked Sendable` because the mutable state below is confined to
/// ``queue``, which the compiler cannot see.
final class IntercomAudioSession: @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()
    private let queue = DispatchQueue(label: "io.music_assistant.client.intercom.audio", qos: .userInitiated)
    /// Whether the local player is producing audio right now. Read on the
    /// main thread, where the recorder and the local player's state live,
    /// before anything is queued — which is why the two methods that ask are
    /// `@MainActor`.
    private let isLocalPlaybackActive: () -> Bool

    /// The category, mode and options the press found. Only touched on ``queue``.
    private var saved: SavedCategory?
    /// The session was already live for local playback when the press took
    /// it, so ending the press must not take it down. Only touched on ``queue``.
    private var leaveActive = false

    private struct SavedCategory {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    /// - Parameter isLocalPlaybackActive: whether the local player is playing.
    ///   The default suits previews and tests, which have none.
    init(isLocalPlaybackActive: @escaping () -> Bool = { false }) {
        self.isLocalPlaybackActive = isLocalPlaybackActive
    }

    // MARK: - Permission

    /// Cheap and safe from any thread, unlike everything below: this is the
    /// app-level flag, not a session call.
    var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Asks for microphone access, returning the resulting permission state.
    func requestPermission() async -> Bool {
        switch permission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Session

    /// Sets the recording category *without* activating the session, so a
    /// spare recorder can be prepared ahead of the press and nothing on the
    /// phone gets ducked.
    ///
    /// - Returns: `false` — having done nothing — while the local player plays.
    @MainActor
    func configure() async -> Bool {
        guard !isLocalPlaybackActive() else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.applyCategory(mixing: false)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Takes the session for one press: notes what it was, switches it to
    /// recording and activates it.
    @MainActor
    func activate() async throws {
        let mixing = isLocalPlaybackActive()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.saved == nil {
                        self.saved = SavedCategory(
                            category: self.session.category,
                            mode: self.session.mode,
                            options: self.session.categoryOptions
                        )
                    }
                    self.leaveActive = mixing
                    try self.applyCategory(mixing: mixing)
                    try self.session.setActive(true)
                    continuation.resume()
                } catch {
                    self.restoreSavedCategory()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fire-and-forget: nothing waits on the session being handed back, and
    /// the serial queue keeps it ordered ahead of the next ``activate()``.
    ///
    /// Puts back the category the press found, then deactivates — unless the
    /// local player had the session live before the press, in which case it
    /// keeps it. `.notifyOthersOnDeactivation` matters: without it other audio
    /// on the phone stays ducked after every announcement.
    func deactivate() {
        queue.async {
            self.restoreSavedCategory()
            guard !self.leaveActive else {
                self.leaveActive = false
                return
            }
            try? self.session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Queue-confined helpers

    /// Must run on ``queue``.
    private func applyCategory(mixing: Bool) throws {
        let options: AVAudioSession.CategoryOptions = mixing
            ? [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            : [.defaultToSpeaker, .allowBluetooth]
        guard session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options else {
            return
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
    }

    /// Must run on ``queue``.
    private func restoreSavedCategory() {
        guard let saved else { return }
        self.saved = nil
        guard saved.category != .playAndRecord else { return }
        try? session.setCategory(saved.category, mode: saved.mode, options: saved.options)
    }
}
