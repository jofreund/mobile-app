import XCTest

/// The intercom grid's state machine, ported with home-intercom's
/// `RoomsViewModelTests`: the press flow, the early hand-off, and the resend
/// rules that keep a message from playing twice. What fed the room grid —
/// loading, polling, the Home Assistant socket — has no counterpart here.
@MainActor
final class IntercomViewModelTests: XCTestCase {
    private let living = IntercomTarget(id: "living", name: "Wohnzimmer", iconId: "speaker", isAnnouncing: false)
    private let kitchen = IntercomTarget(id: "kitchen", name: "Küche", iconId: "speaker", isAnnouncing: false)

    private func makeViewModel(sender: PreviewAnnouncementSender, isAvailable: Bool = true) -> IntercomViewModel {
        sender.delay = .zero
        let viewModel = IntercomViewModel(sender: sender, recorder: IntercomRecorder())
        viewModel.update(targets: [living, kitchen], isAvailable: isAvailable)
        return viewModel
    }

    /// Waits for a view-model change driven by its own consuming task.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 64).write(to: url)
        return url
    }

    // MARK: - Targets

    /// A server without spoken announcements leaves every card on the grid but
    /// takes no press.
    func testNoCardIsPressableWithoutSpokenAnnouncements() {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender(), isAvailable: false)

        XCTAssertEqual(viewModel.targets, [living, kitchen])
        XCTAssertFalse(viewModel.isPressable(living))

        viewModel.update(targets: [living, kitchen], isAvailable: true)
        XCTAssertTrue(viewModel.isPressable(living))
    }

    /// A player that goes away takes everything the grid held for it along —
    /// least of all a recording waiting for a resend.
    func testAPlayerThatLeavesTakesItsRecordingAlong() async throws {
        let sender = PreviewAnnouncementSender(error: .notSent(reason: nil))
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()
        await viewModel.upload(clip: clip, to: living)
        XCTAssertTrue(viewModel.hasPendingUpload(living))

        viewModel.update(targets: [kitchen], isAvailable: true)

        XCTAssertEqual(viewModel.targets, [kitchen])
        XCTAssertNil(viewModel.cardStates[living.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
    }

    /// A press holds the grid still: a list that arrives while a card is
    /// claimed waits until the grid is handed back.
    func testAPressHoldsTheGridStill() async {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender())

        viewModel.pressBegan(on: living)
        await waitUntil("the press to claim its card") { viewModel.state(for: living) == .arming }
        viewModel.update(targets: [kitchen], isAvailable: true)
        XCTAssertEqual(viewModel.targets, [living, kitchen])

        viewModel.pressEnded(on: living)
        XCTAssertEqual(viewModel.targets, [kitchen])
    }

    // MARK: - Failures and resends

    /// A recording whose send failed must survive on disk — losing a held
    /// message to a flaky network is the one failure worth a second button.
    func testFailedSendKeepsTheRecordingForRetry() async throws {
        let sender = PreviewAnnouncementSender(error: .notSent(reason: nil))
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()

        await viewModel.upload(clip: clip, to: living)

        XCTAssertEqual(
            viewModel.state(for: living),
            .failed(message: AnnouncementError.notSent(reason: nil).message, canRetry: true)
        )
        XCTAssertTrue(viewModel.hasPendingUpload(living))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        // The tile belongs to its resend/discard buttons until the user decides.
        XCTAssertFalse(viewModel.isPressable(living))
    }

    /// A clip cut short still plays the part that arrived, so the card says a
    /// resend may play it twice.
    func testACutShortClipWarnsBeforeResending() async throws {
        let sender = PreviewAnnouncementSender(error: .cutShort)
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()

        await viewModel.upload(clip: clip, to: living)

        XCTAssertEqual(
            viewModel.state(for: living),
            .failed(
                message: String(
                    format: String(localized: "intercom_failed_may_have_played"),
                    AnnouncementError.cutShort.message
                ),
                canRetry: true
            )
        )
    }

    func testRetrySendsTheKeptRecordingAndCleansUp() async throws {
        let sender = PreviewAnnouncementSender(error: .notSent(reason: nil))
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()
        await viewModel.upload(clip: clip, to: living)

        sender.error = nil
        viewModel.retrySend(on: living)
        // "Gesendet" comes as the clip leaves; the clean-up once the send returns.
        await waitUntil("the retry to succeed and settle") {
            viewModel.state(for: living) == .sent && !viewModel.hasPendingUpload(living)
        }

        XCTAssertEqual(sender.sentPlayerIds, ["living"])
        XCTAssertFalse(viewModel.hasPendingUpload(living))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertTrue(viewModel.isPressable(living))
    }

    func testDiscardingAPendingRecordingRemovesTheFile() async throws {
        let sender = PreviewAnnouncementSender(error: .notSent(reason: nil))
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()
        await viewModel.upload(clip: clip, to: living)

        viewModel.discardPendingUpload(on: living)

        XCTAssertEqual(viewModel.state(for: living), .idle)
        XCTAssertFalse(viewModel.hasPendingUpload(living))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
    }

    /// A successful send must not leave the recording behind in `tmp`.
    func testSuccessfulSendDeletesTheRecording() async throws {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender())
        let clip = try makeTemporaryFile()

        await viewModel.upload(clip: clip, to: living)

        XCTAssertEqual(viewModel.state(for: living), .sent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
    }

    func testCancellingWithoutARecordingDoesNothing() {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender())

        viewModel.cancelActiveRecording(message: "Aufnahme unterbrochen")

        XCTAssertTrue(viewModel.cardStates.isEmpty)
    }

    // MARK: - Early hand-off

    /// The server answers only once the player has finished the announcement.
    /// Holding the card until then would lock the grid for the whole
    /// announcement, so it is released as soon as the clip has left.
    func testCardIsReleasedWhenTheClipHasLeftTheDevice() async throws {
        let sender = PreviewAnnouncementSender()
        // Stands in for the player speaking the announcement before the answer.
        sender.playbackDelay = .seconds(30)
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()

        let upload = Task { await viewModel.upload(clip: clip, to: living) }
        defer { upload.cancel() }

        await waitUntil("the card to be handed back") { viewModel.state(for: living) == .sent }
        // Still mid-send — and the grid is already usable again.
        XCTAssertNil(viewModel.activeTarget)
        XCTAssertTrue(viewModel.isPressable(living))
        XCTAssertTrue(viewModel.isPressable(kitchen))
    }

    /// Playback that failed after the clip went out reopens the card — and
    /// says the message may have played, because all of it was out.
    func testFailureAfterTheClipLeftReopensTheCard() async throws {
        let sender = PreviewAnnouncementSender(error: .playbackFailed(reason: nil))
        sender.playbackDelay = .milliseconds(20)
        sender.failsAfterAudioLeft = true
        let viewModel = makeViewModel(sender: sender)
        let clip = try makeTemporaryFile()

        await viewModel.upload(clip: clip, to: living)

        XCTAssertEqual(
            viewModel.state(for: living),
            .failed(
                message: String(
                    format: String(localized: "intercom_failed_may_have_played"),
                    AnnouncementError.playbackFailed(reason: nil).message
                ),
                canRetry: true
            )
        )
        XCTAssertTrue(viewModel.hasPendingUpload(living))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
    }

    /// A failure that only shows up after the clip left must not be pinned on
    /// a card the user has meanwhile started the next message on.
    func testStaleFailureLeavesTheNextMessageAlone() async throws {
        let sender = PreviewAnnouncementSender(error: .playbackFailed(reason: nil))
        sender.playbackDelay = .seconds(30)
        sender.failsAfterAudioLeft = true
        let viewModel = makeViewModel(sender: sender)
        let first = try makeTemporaryFile()

        let stale = Task { await viewModel.upload(clip: first, to: living) }
        defer { stale.cancel() }
        await waitUntil("the first card to be handed back") { viewModel.state(for: living) == .sent }

        // The user records again on the same card before the first one answers.
        sender.playbackDelay = .zero
        sender.failsAfterAudioLeft = false
        sender.error = nil
        let second = try makeTemporaryFile()
        await viewModel.upload(clip: second, to: living)

        XCTAssertEqual(viewModel.state(for: living), .sent)
        XCTAssertFalse(viewModel.hasPendingUpload(living))
    }

    // MARK: - The press

    /// Touch-down on its own writes nothing the grid can see: the pressed
    /// card is untouched, and so are the others, which dim as soon as one
    /// press owns the grid.
    func testTouchDownChangesNothing() {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender())

        viewModel.pressBegan(on: living)

        XCTAssertEqual(viewModel.state(for: living), .idle)
        XCTAssertNil(viewModel.activeTarget)
        XCTAssertTrue(viewModel.isPressable(kitchen))

        viewModel.pressEnded(on: living)
    }

    /// A tap leaves the grid exactly as it found it. No recording, nothing
    /// sent, and no "zu kurz" to read either — the user saw nothing happen,
    /// so there is nothing to explain. Only the hint goes up.
    func testATapLeavesNoTrace() {
        let sender = PreviewAnnouncementSender()
        let viewModel = makeViewModel(sender: sender)

        viewModel.pressBegan(on: living)
        viewModel.pressEnded(on: living)

        XCTAssertEqual(viewModel.state(for: living), .idle)
        XCTAssertNil(viewModel.activeTarget)
        XCTAssertFalse(viewModel.hasPendingUpload(living))
        XCTAssertEqual(sender.sentPlayerIds, [])
        XCTAssertTrue(viewModel.showsHoldHint)
    }

    /// Held past ``IntercomViewModel/armDelay`` the press claims its card and
    /// arms it, which is what starts the pop-over growing. The mic goes no
    /// further until the view reports that growth finished.
    func testAHeldPressArmsItsCardAndThenWaits() async {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender())

        viewModel.pressBegan(on: living)
        await waitUntil("the press to claim its card") { viewModel.state(for: living) == .arming }

        XCTAssertEqual(viewModel.activeTarget, living.id)
        XCTAssertFalse(viewModel.isPressable(kitchen))
        // Still only armed: nothing here opens the mic by itself, which is
        // also why this test never needs one.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(viewModel.state(for: living), .arming)

        viewModel.pressEnded(on: living)
        XCTAssertEqual(viewModel.state(for: living), .tooShort)
    }

    /// A press let go before the mic was live leaves the card wearing its
    /// microphone, so it has to answer the next press right away instead of
    /// sitting out the result linger like a real outcome would.
    func testACardPressedTooBrieflyTakesTheNextPressAtOnce() async {
        let viewModel = makeViewModel(sender: PreviewAnnouncementSender())

        viewModel.pressBegan(on: living)
        await waitUntil("the press to claim its card") { viewModel.state(for: living) == .arming }
        viewModel.pressEnded(on: living)
        XCTAssertEqual(viewModel.state(for: living), .tooShort)

        viewModel.pressBegan(on: living)
        await waitUntil("the next press to claim the card") { viewModel.state(for: living) == .arming }
        XCTAssertEqual(viewModel.activeTarget, living.id)

        viewModel.pressEnded(on: living)
    }

    /// The wait in front of everything a press does has to outlast an actual
    /// tap — several frames of one, not the one or two a warm recorder needs
    /// to start capturing.
    func testTheArmDelayOutlastsATap() {
        XCTAssertGreaterThanOrEqual(IntercomViewModel.armDelay, .milliseconds(100))
    }
}
