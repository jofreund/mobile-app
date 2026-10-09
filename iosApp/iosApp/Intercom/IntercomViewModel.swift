import Foundation
import Observation

/// Drives the intercom grid: the record → send state machine of every card.
///
/// home-intercom's `RoomsViewModel`, with Music Assistant players in place of
/// Home Assistant rooms. Everything that loaded, polled and watched rooms is
/// gone: the player list arrives from `PlayerBarStore` through
/// ``update(targets:isAvailable:)``. The press and the send are unchanged, down
/// to the early hand-off — the server answers only after the announcement has
/// played, so the card is given back as soon as the clip has left.
@MainActor
@Observable
final class IntercomViewModel {
    /// Lifecycle of a single card. Terminal states reset themselves after a
    /// short delay so the grid always returns to a pressable state.
    enum CardState: Equatable {
        case idle
        /// The mic is being brought up; nothing is being captured yet.
        case arming
        case recording
        case sending
        case sent
        /// Discarded without the user's say-so — the system took the
        /// announcement away. A deliberate slide-off goes straight to `idle`.
        case cancelled(reason: String?)
        /// Let go before the mic was ever live. Its own state rather than a
        /// `cancelled` with a reason: nothing was recorded and nothing was
        /// taken away, so the card only explains itself in its detail line
        /// and otherwise stays the idle, pressable card it was — the user's
        /// next move is simply to press again, and the card still invites it.
        case tooShort
        /// `canRetry` means the recording is still on disk and can be resent.
        case failed(message: String, canRetry: Bool)

        var isBusy: Bool {
            self == .arming || self == .recording || self == .sending
        }
    }

    /// The grid, in the player list's order.
    private(set) var targets: [IntercomTarget] = []
    /// The signed-in server takes spoken announcements. Without it no card is
    /// pressable.
    private(set) var isAvailable = false
    private(set) var cardStates: [String: CardState] = [:]
    /// The card currently being recorded for — at most one at a time.
    private(set) var activeTarget: String?
    var showsMicrophonePermissionAlert = false
    /// Whether the line above the grid spells the gesture out. Off until a
    /// press turns out to have been a tap — someone who holds the card and
    /// speaks never needs telling, and the grid stays as quiet as they left
    /// it. A tap is the one moment the hint answers a question the user has
    /// just asked, so it appears then and stays until a press works — and
    /// then until that card has finished sliding back into the grid, so the
    /// line is never pulled out from under a pop-over that is still on its
    /// way home. See ``cardDidReturnToGrid()``.
    private(set) var showsHoldHint = false

    /// How long a finished card keeps showing its result.
    static let resultLingerDuration: Duration = .seconds(2)
    /// How long a recording may run before it is stopped and sent. The server
    /// takes five minutes; an intercom message is a sentence or two, and
    /// home-intercom's integration capped it at one.
    static let maxRecordingDuration: Duration = .seconds(60)
    /// How long to leave the main thread alone before building the next spare
    /// recorder — see ``warmUpAfterInteraction()``. Comfortably longer than
    /// the pop-over's collapse.
    static let warmUpDelay: Duration = .milliseconds(400)
    /// How long a press has to last before anything happens at all — the line
    /// between a tap and a press, and so the start of everything in the flow
    /// described on ``pressBegan(on:)``.
    ///
    /// Under it nothing has happened, in the strong sense: nothing was drawn,
    /// claimed, felt or recorded, and there is nothing to take back. Over it
    /// the card grows, and the tap and the mic follow it in that order. A
    /// warm recorder is capturing within a frame or two of being asked, so
    /// without this wait a stray tap reached `.recording`, was released
    /// again, and left the card saying "Gesendet" for a fingertip's worth of
    /// silence — behind a pop-over that had flashed open and shut.
    ///
    /// Long enough that no deliberate press reads as a twitch, short enough
    /// that a press the user means does not feel like it is being considered.
    static let armDelay: Duration = .milliseconds(100)

    private let sender: any AnnouncementSending
    private let recorder: IntercomRecorder

    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    /// The press that has not yet outlasted a tap — step 1 of the flow
    /// described on ``pressBegan(on:)``. Deliberately not observable: a write
    /// the grid can see is exactly what a tap must not cause.
    @ObservationIgnored private var pendingPress: String?
    /// A press has reached the microphone since the hint went up, so the hint
    /// has done its job — it is only taken down once that card has landed
    /// back in the grid. Not observable: on its own it changes nothing on
    /// screen.
    @ObservationIgnored private var holdReachedMic = false
    /// The ``armDelay`` wait that decides whether a press is a press.
    @ObservationIgnored private var pressWaitTask: Task<Void, Never>?
    /// Bringing the mic up once the card has arrived.
    @ObservationIgnored private var micTask: Task<Void, Never>?
    @ObservationIgnored private var warmUpTask: Task<Void, Never>?
    @ObservationIgnored private var resetTasks: [String: Task<Void, Never>] = [:]
    /// Recordings whose send failed, kept on disk so they can be resent
    /// instead of being lost to a flaky network.
    @ObservationIgnored private var pendingUploads: [String: URL] = [:]
    /// Cards whose recording has already left the device while the send is
    /// still open. Their card has been handed back to the user, so the
    /// result — when it finally arrives — must not touch it unless something
    /// went wrong. See ``audioDidLeaveDevice(for:upload:)``.
    @ObservationIgnored private var releasedEarly: Set<String> = []
    /// The send currently in flight per card. A result whose id no longer
    /// matches belongs to a message the user has already followed with another.
    @ObservationIgnored private var uploadIDs: [String: UUID] = [:]
    /// The latest player list, while a press holds the grid still — see
    /// ``update(targets:isAvailable:)``.
    @ObservationIgnored private var deferredTargets: [IntercomTarget]?

    init(sender: any AnnouncementSending, recorder: IntercomRecorder) {
        self.sender = sender
        self.recorder = recorder
        recorder.onInterruption = { [weak self] in
            self?.handleInterruption()
        }
    }

    // MARK: - Targets

    /// Takes the latest player list and whether the server takes spoken
    /// announcements at all.
    ///
    /// The list is rebuilt on every Kotlin emission — a volume change on any
    /// player is one — and is usually the one already on screen. Assigning it
    /// anyway redraws the whole grid, glass included, so only a real change
    /// is written.
    func update(targets: [IntercomTarget], isAvailable: Bool) {
        if isAvailable != self.isAvailable {
            self.isAvailable = isAvailable
        }
        // A press holds the grid still, as home-intercom's room reload did: a
        // card that moved under the finger — or vanished from under it — would
        // take the press with it. The list waits until the grid is handed back.
        guard activeTarget == nil, pendingPress == nil else {
            deferredTargets = targets
            return
        }
        apply(targets)
    }

    private func apply(_ targets: [IntercomTarget]) {
        deferredTargets = nil
        guard targets != self.targets else { return }
        self.targets = targets
        forgetTargets(exceptFor: Set(targets.map(\.id)))
    }

    /// Hands the grid back after a press: clears ``activeTarget`` and applies
    /// a player list that arrived while the press held the grid still.
    private func releaseGrid() {
        activeTarget = nil
        if pendingPress == nil, let deferredTargets { apply(deferredTargets) }
    }

    func state(for target: IntercomTarget) -> CardState {
        cardStates[target.id] ?? .idle
    }

    func isPressable(_ target: IntercomTarget) -> Bool {
        guard isAvailable else { return false }
        // A card offering "resend" belongs to its buttons until the user has
        // decided what to do with the recording. A resend whose audio is
        // already out is not one of those: its card has been handed back and
        // takes the next press, even though the file is still on disk pending
        // the answer.
        guard pendingUploads[target.id] == nil || releasedEarly.contains(target.id) else { return false }
        // While one card records, the others are inert.
        return activeTarget == nil || activeTarget == target.id
    }

    /// True while a failed recording for this card is still on disk.
    func hasPendingUpload(_ target: IntercomTarget) -> Bool {
        pendingUploads[target.id] != nil
    }

    /// The live meter behind the pop-over's waveform. The view reads its
    /// levels itself, so the twenty-five-a-second updates redraw the waveform
    /// and nothing else.
    var levelMeter: IntercomRecorder { recorder }

    /// Brings microphone, audio session, and the Taptic Engine up before the
    /// first press, so the card never says "speak" while the mic is still
    /// starting and the very first press still feels the start haptic.
    func prepareRecorder() {
        recorder.warmUp()
        Haptics.prepare()
    }

    /// Drops everything the grid still held for players that are gone —
    /// including any recording waiting on disk for a resend to a player that
    /// is no longer there.
    private func forgetTargets(exceptFor ids: Set<String>) {
        let held = Set(cardStates.keys).union(pendingUploads.keys)
        for id in held where !ids.contains(id) {
            cancelReset(for: id)
            discardPendingFile(for: id)
            cardStates[id] = nil
            uploadIDs[id] = nil
            releasedEarly.remove(id)
        }
    }

    // MARK: - Record & send

    /// Touch-down. What follows is the whole press, in order — nothing here
    /// happens earlier than it says, and a tap never reaches step 2:
    ///
    /// 1. **Touch-down.** Nothing at all. No card state, no ``activeTarget``,
    ///    no pop-over, no tap you can feel, no recorder. A press this young
    ///    may still turn out to be a tap, and a tap has to leave the grid
    ///    exactly as it found it — the pressed card *and* the others, which
    ///    dim as soon as one press owns the grid. Released here, the press
    ///    simply evaporates: nothing was shown, felt or recorded, so there is
    ///    nothing to undo and nothing to report.
    /// 2. **``armDelay`` later, finger still down.** The press is real. The
    ///    card is claimed and set to `.arming`, which is what lets
    ///    `IntercomView` build the pop-over and grow it out of the grid.
    /// 3. **The pop-over has finished growing.** `IntercomView` says so by
    ///    calling ``cardDidFinishGrowing(on:)``: the start tap fires, and the
    ///    mic opens behind it. `.recording` follows once the recorder is
    ///    genuinely capturing, so nobody speaks into a dead mic.
    /// 4. **Release.** ``pressEnded(on:)`` sends — or, if the mic was not
    ///    live yet, discards quietly. Nothing reaches the server before this
    ///    point, which is what makes every way of not sending possible: the
    ///    server plays any clip that has audio in it.
    func pressBegan(on target: IntercomTarget) {
        // `.tooShort` counts as idle here: the card is still wearing its
        // microphone, so it has to answer a press like the idle card it looks
        // like. Every other terminal state has its result to finish showing
        // first.
        let current = state(for: target)
        guard isPressable(target), current == .idle || current == .tooShort, activeTarget == nil else { return }
        // Nothing from the last press may still be in flight — a press that
        // ended in a failure leaves its finished work behind, and step 3
        // refuses to run while it looks like the mic is already coming up.
        endPress()
        // Step 1: noted, and nothing more.
        pendingPress = target.id

        pressWaitTask = Task { [weak self] in
            try? await Task.sleep(for: IntercomViewModel.armDelay)
            guard !Task.isCancelled, let self, pendingPress == target.id else { return }
            // Step 2. From here the grid is allowed to move.
            pendingPress = nil
            activeTarget = target.id
            cancelReset(for: target.id)
            setState(.arming, for: target.id)
        }
    }

    /// Step 3: the pop-over has finished growing and the card the user is
    /// about to speak into is fully there.
    ///
    /// Driven from the view rather than from a second timer here, because the
    /// expand animation is the only thing that knows when it is done.
    ///
    /// The tap goes before the mic, not after: iOS attenuates Taptic feedback
    /// while the audio session is actively recording (to keep the motor's buzz
    /// out of the recording), so firing behind `recorder.start()` made it land
    /// inconsistently. It is also the order the user reads it in — the tap
    /// says the microphone is yours, and then it is.
    func cardDidFinishGrowing(on target: IntercomTarget) {
        guard activeTarget == target.id, state(for: target) == .arming, micTask == nil else { return }
        Haptics.recordingStarted()

        micTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
                // The press may already have ended while the permission
                // prompt or session activation was in flight.
                guard activeTarget == target.id, state(for: target) == .arming else {
                    recorder.cancel()
                    return
                }
                setState(.recording, for: target.id)
                // The gesture landed: whoever needed the line has read it.
                // Noted, not acted on — the line goes once the card is back
                // in the grid, see ``cardDidReturnToGrid()``.
                holdReachedMic = true
                startMaxDurationTimer(for: target)
                // The rush is over: the card has landed, the mic is up, and
                // the release is a held moment away.
                Haptics.prepareForRelease()
            } catch IntercomRecorder.RecorderError.permissionDenied {
                showsMicrophonePermissionAlert = true
                finishWithFailure(String(localized: "intercom_error_no_microphone"), for: target.id)
            } catch {
                finishWithFailure(String(localized: "intercom_error_microphone_unavailable"), for: target.id)
            }
        }
    }

    /// The pop-over has finished shrinking and the card is fully back on its
    /// tile. Driven from the view for the same reason as
    /// ``cardDidFinishGrowing(on:)``: the collapse animation is the only
    /// thing that knows when it is over.
    ///
    /// The one place the hold hint is taken down. Dropping it the moment the
    /// mic opened would have moved the grid — and with it the tile the
    /// pop-over is aiming at — while the card was still in the air.
    func cardDidReturnToGrid() {
        guard holdReachedMic else { return }
        holdReachedMic = false
        showsHoldHint = false
    }

    func pressEnded(on target: IntercomTarget) {
        // A tap: let go inside ``armDelay``, before step 2 of the flow on
        // ``pressBegan(on:)``. Nothing was claimed, shown, felt or recorded,
        // so this is the whole of it — except that the user has just tried to
        // talk by tapping, which is the one thing the hint is for.
        if pendingPress == target.id {
            endPress()
            releaseGrid()
            showsHoldHint = true
            return
        }
        guard activeTarget == target.id else { return }
        let current = state(for: target)
        guard current == .arming || current == .recording else { return }
        // Let go while the card was still growing, or in the frame or two the
        // mic takes to come up behind it. There is no audio in a press that
        // short, and saying so beats sending a fingertip's worth of silence
        // — quietly, though, since the tap that would have marked the start
        // never played either: see the `feedback` parameter.
        if current == .arming {
            abortRecording(outcome: .tooShort, for: target.id, feedback: false)
            // Held a moment longer than a tap, but still let go before there
            // was a microphone: the same misunderstanding, so the same line.
            showsHoldHint = true
            return
        }
        endPress()
        Haptics.recordingStopped()
        setState(.sending, for: target.id)

        Task { [weak self] in
            guard let self else { return }
            do {
                // Stopping is asynchronous: the recorder has to close its file
                // before the bytes are safe to send.
                let clip = try await recorder.stop()
                await upload(clip: clip, to: target)
            } catch let error as IntercomRecorder.RecorderError {
                finishWithFailure(
                    error.errorDescription ?? String(localized: "intercom_error_recording_failed"),
                    for: target.id
                )
            } catch {
                finishWithFailure(String(localized: "intercom_error_recording_failed"), for: target.id)
            }
            recorder.warmUp()
        }
    }

    /// The finger slid off the card — discard instead of announcing. The user
    /// did this on purpose and can see it happen, so the card goes straight
    /// back to idle rather than lingering on "Abgebrochen" and blocking the
    /// next press.
    func pressCancelled(on target: IntercomTarget) {
        // Slid off and let go inside ``armDelay``: a tap that happened to
        // travel. Same as any other tap — nothing happened, nothing to say.
        if pendingPress == target.id {
            endPress()
            releaseGrid()
            return
        }
        guard activeTarget == target.id, state(for: target).isBusy, state(for: target) != .sending else { return }
        endPress()
        recorder.cancel()
        Haptics.recordingCancelled()
        cancelReset(for: target.id)
        setState(.idle, for: target.id)
        releaseGrid()
        warmUpAfterInteraction()
    }

    /// Drops everything one press owns that is not card state: the waits in
    /// front of it and the pending-press marker. Card state is left to the
    /// caller, which is the only one that knows what the press ended as.
    private func endPress() {
        pendingPress = nil
        pressWaitTask?.cancel()
        pressWaitTask = nil
        micTask?.cancel()
        micTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
    }

    /// Cancels the current recording without sending — used when a press is
    /// interrupted by the system.
    func cancelActiveRecording(message: String) {
        // A press still inside ``armDelay`` has nothing to cancel — it is not
        // a recording yet — but it must not become one either.
        if pendingPress != nil {
            endPress()
            releaseGrid()
        }
        // Only an in-flight *recording* is cancellable; a send that is
        // already on its way is left to finish.
        guard let target = activeTarget, cardStates[target]?.isBusy == true, cardStates[target] != .sending else {
            return
        }
        abortRecording(outcome: .cancelled(reason: message), for: target)
    }

    /// Resends a recording whose send failed. The file is still on disk.
    func retrySend(on target: IntercomTarget) {
        guard let clip = pendingUploads[target.id], activeTarget == nil else { return }
        activeTarget = target.id
        cancelReset(for: target.id)
        setState(.sending, for: target.id)
        Task { [weak self] in
            await self?.upload(clip: clip, to: target)
        }
    }

    /// Throws away a recording the user has decided not to resend.
    func discardPendingUpload(on target: IntercomTarget) {
        discardPendingFile(for: target.id)
        cancelReset(for: target.id)
        setState(.idle, for: target.id)
    }

    /// - Parameters:
    ///   - outcome: what the card is left saying — ``CardState/tooShort`` for
    ///     a release before the mic was live, `cancelled` for an announcement
    ///     the system took away.
    ///   - feedback: whether to play the two-beat cancel tap. Off for
    ///     a press that never got as far as the start tap: nothing marked the
    ///     beginning, so a heavier buzz to mark the end reads as something
    ///     having gone wrong — where nothing did, the finger simply did not
    ///     stay. The card still says "Zu kurz gehalten" for anyone who looks.
    ///     An announcement the *system* took away is the other case, and does
    ///     buzz: there the user has no way of knowing otherwise.
    private func abortRecording(outcome: CardState, for id: String, feedback: Bool = true) {
        endPress()
        recorder.cancel()
        if feedback { Haptics.recordingCancelled() }
        setState(outcome, for: id)
        scheduleReset(for: id)
        // Last: a deferred list may drop this very card, timer and all.
        releaseGrid()
        warmUpAfterInteraction()
    }

    /// Internal rather than private so the failure/retry path can be driven
    /// from tests without a microphone.
    ///
    /// The card is not held for the whole send. The server answers only once
    /// the player has finished the announcement, so waiting for it would keep
    /// the grid locked for the length of the announcement plus everything the
    /// player adds on top. The card is handed back the moment the clip has
    /// left the device (``audioDidLeaveDevice(for:upload:)``); the result is
    /// then read only for what may still have gone wrong.
    func upload(clip: URL, to target: IntercomTarget) async {
        let id = target.id
        // Identifies this send for as long as it is in flight, so a result
        // that arrives after the user has started the next message on the
        // same card can tell that the card is no longer its own.
        let upload = UUID()
        uploadIDs[id] = upload
        releasedEarly.remove(id)
        setState(.sending, for: id)

        do {
            try await sender.send(clip: clip, to: id) { [weak self] in
                self?.audioDidLeaveDevice(for: id, upload: upload)
            }
            let outcome = finishUpload(for: id, upload: upload)
            guard outcome != .superseded else {
                // A newer message owns this card — and possibly this very
                // file, if it is a resend of it. Clean up only what is still
                // ours.
                discardRecording(clip, for: id)
                return
            }
            discardPendingFile(for: id)
            discardRecording(clip, for: id)
            // Either the card still waits for this — then say "Gesendet" — or
            // it already does, and there is nothing to add.
            guard outcome == .held else { return }
            Haptics.success()
            setState(.sent, for: id)
            scheduleReset(for: id)
        } catch {
            let outcome = finishUpload(for: id, upload: upload)
            guard mayReport(outcome, for: id) else {
                // The card belongs to the next message already — reopening
                // this failure on it would fight the user for it.
                discardRecording(clip, for: id)
                return
            }
            // The recording survives the failure: losing a message to a flaky
            // Wi-Fi hop is the one thing worth a second button.
            pendingUploads[id] = clip
            let announcementError = error as? AnnouncementError ?? .notSent(reason: nil)
            // A send is not idempotent: the server plays whatever audio it
            // got. When the failure leaves the outcome open, say so on the
            // card — resending may play the message twice.
            let message = outcome == .released || announcementError.mayHaveBeenDelivered
                ? String(format: String(localized: "intercom_failed_may_have_played"), announcementError.message)
                : announcementError.message
            Haptics.failure()
            // No auto-reset — the card waits for "resend" or "discard".
            cancelReset(for: id)
            setState(.failed(message: message, canRetry: true), for: id)
        }
    }

    /// What a finished send is still allowed to do to its card.
    enum UploadOutcome: Equatable {
        /// The card waited for the result; it is this send's to set.
        case held
        /// The card was handed back when the clip left the device. Only a
        /// problem is worth showing, and only while the card is free.
        case released
        /// A newer recording owns the card — this result is stale.
        case superseded
    }

    /// The clip is on its way and the phone is done with it: say "Gesendet"
    /// now instead of holding the card for the whole announcement.
    ///
    /// Deliberately optimistic — playback can still fail. That comes back
    /// through ``upload(clip:to:)``, which reopens the card.
    private func audioDidLeaveDevice(for id: String, upload: UUID) {
        guard uploadIDs[id] == upload, cardStates[id] == .sending, !releasedEarly.contains(id) else { return }
        releasedEarly.insert(id)
        Haptics.success()
        setState(.sent, for: id)
        scheduleReset(for: id)
        if activeTarget == id { releaseGrid() }
    }

    /// Whether a finished send may still write to its card: only while the
    /// user has not claimed it for the next message.
    private func mayReport(_ outcome: UploadOutcome, for id: String) -> Bool {
        switch outcome {
        case .held: true
        case .released: activeTarget != id && cardStates[id]?.isBusy != true
        case .superseded: false
        }
    }

    /// Closes the books on one send and reports what it may still show.
    private func finishUpload(for id: String, upload: UUID) -> UploadOutcome {
        guard uploadIDs[id] == upload else { return .superseded }
        uploadIDs[id] = nil
        guard releasedEarly.remove(id) != nil else {
            if activeTarget == id { releaseGrid() }
            return .held
        }
        return .released
    }

    /// Deletes a recording the app is finished with — unless it is the very
    /// file a newer send for this card is still streaming.
    private func discardRecording(_ clip: URL, for id: String) {
        guard pendingUploads[id] != clip else { return }
        try? FileManager.default.removeItem(at: clip)
    }

    private func discardPendingFile(for id: String) {
        guard let clip = pendingUploads.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: clip)
    }

    /// Stops and sends rather than letting the recording run on — see
    /// ``maxRecordingDuration``.
    private func startMaxDurationTimer(for target: IntercomTarget) {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: IntercomViewModel.maxRecordingDuration)
            guard !Task.isCancelled, let self, self.activeTarget == target.id else { return }
            Haptics.warning()
            self.pressEnded(on: target)
        }
    }

    /// Builds the next spare recorder once the pop-over has landed.
    ///
    /// `AVAudioRecorder`'s initialiser and `prepareToRecord()` both have to
    /// run on the main thread — see ``IntercomAudioSession`` — and both are
    /// session calls of the kind iOS warns can hang the UI. Called straight
    /// from a release or a slide-off, they land in the middle of the third of
    /// a second the pop-over spends springing back onto its tile. A spare
    /// recorder is a prefetch for a press that has not happened yet; it can
    /// wait for the animation.
    private func warmUpAfterInteraction() {
        warmUpTask?.cancel()
        warmUpTask = Task { [weak self] in
            try? await Task.sleep(for: IntercomViewModel.warmUpDelay)
            guard !Task.isCancelled else { return }
            self?.recorder.warmUp()
        }
    }

    private func handleInterruption() {
        cancelActiveRecording(message: String(localized: "intercom_recording_interrupted"))
    }

    // MARK: - State plumbing

    private func setState(_ state: CardState, for id: String) {
        cardStates[id] = state
    }

    private func finishWithFailure(_ message: String, for id: String) {
        Haptics.failure()
        setState(.failed(message: message, canRetry: false), for: id)
        scheduleReset(for: id)
        releaseGrid()
    }

    private func scheduleReset(for id: String) {
        cancelReset(for: id)
        resetTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: IntercomViewModel.resultLingerDuration)
            guard !Task.isCancelled else { return }
            self?.cardStates[id] = .idle
            self?.resetTasks[id] = nil
        }
    }

    private func cancelReset(for id: String) {
        resetTasks[id]?.cancel()
        resetTasks[id] = nil
    }
}
