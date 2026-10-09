import XCTest

/// The server plays every clip that has audio in it, also when the link drops
/// half-way — so a send is not idempotent, and every resend decision hangs on
/// how far the clip got. Get that wrong and the message plays twice. The
/// counterpart of home-intercom's `UploadRetrySafetyTests`.
final class AnnouncementErrorTests: XCTestCase {
    func testAPlayedClipIsNoError() {
        XCTAssertNil(AnnouncementError.from(played: true, reason: nil, audioSent: true, stopSent: true))
    }

    /// Nothing reached the server: a resend cannot play it twice.
    func testARejectionBeforeAnyAudioIsSafeToResend() {
        let error = AnnouncementError.from(
            played: false,
            reason: "Too many live announcements in progress",
            audioSent: false,
            stopSent: false
        )
        XCTAssertEqual(error, .notSent(reason: "Too many live announcements in progress"))
        XCTAssertEqual(error?.message, "Too many live announcements in progress")
        XCTAssertFalse(error?.mayHaveBeenDelivered ?? true)
    }

    /// The link went away mid-clip: the server plays the part that arrived.
    func testALinkLostMidClipMayHavePlayed() {
        let error = AnnouncementError.from(played: false, reason: nil, audioSent: true, stopSent: false)
        XCTAssertEqual(error, .cutShort)
        XCTAssertTrue(error?.mayHaveBeenDelivered ?? false)
    }

    /// All of it and the stop went out, then the link went: the server plays
    /// what it has, so there is nothing to report.
    func testALinkLostAfterTheStopIsNoError() {
        XCTAssertNil(AnnouncementError.from(played: false, reason: nil, audioSent: true, stopSent: true))
    }

    /// The server said playing failed: worth showing, and a resend may repeat
    /// whatever did play.
    func testAPlaybackErrorAfterTheStopIsShown() {
        let error = AnnouncementError.from(
            played: false,
            reason: "Player is no longer available",
            audioSent: true,
            stopSent: true
        )
        XCTAssertEqual(error, .playbackFailed(reason: "Player is no longer available"))
        XCTAssertTrue(error?.mayHaveBeenDelivered ?? false)
    }
}
