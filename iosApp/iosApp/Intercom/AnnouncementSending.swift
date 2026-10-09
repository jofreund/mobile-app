import Foundation

/// Sends a finished recording as a spoken announcement — the seam between the
/// intercom view model and the Kotlin kernel, so the view model and its tests
/// never import `MusicAssistantKit`. home-intercom's `IntercomClienting.send`,
/// with a player in place of a room.
protocol AnnouncementSending: Sendable {
    /// Streams the recording at `clip` to `playerId` and resolves once the
    /// server reports that it has played. Throws ``AnnouncementError``.
    ///
    /// `onAudioLeftDevice` fires earlier: the moment the whole clip and the
    /// stop have gone out. From there on the server plays it whatever happens
    /// to the connection, so the UI can stop waiting on the user's behalf. It
    /// is called at most once per send, on the main actor.
    func send(clip: URL, to playerId: String, onAudioLeftDevice: (@MainActor @Sendable () -> Void)?) async throws
}

/// Fixture sender for SwiftUI previews and tests — no network involved.
final class PreviewAnnouncementSender: AnnouncementSending, @unchecked Sendable {
    var error: AnnouncementError?
    /// Artificial latency so previews show the sending state.
    var delay: Duration = .milliseconds(300)
    /// How long ``send(clip:to:onAudioLeftDevice:)`` keeps waiting *after* the
    /// audio has left — the server answers only once the announcement has
    /// played, so this is what the early hand-off is measured against.
    var playbackDelay: Duration = .zero
    /// Whether a failing send still gets the audio out first. False models a
    /// clip that never reached the server; true one whose playback failed.
    var failsAfterAudioLeft = false

    private(set) var sentPlayerIds: [String] = []

    init(error: AnnouncementError? = nil) {
        self.error = error
    }

    func send(clip: URL, to playerId: String, onAudioLeftDevice: (@MainActor @Sendable () -> Void)?) async throws {
        if delay > .zero { try? await Task.sleep(for: delay) }
        // A send that never got its audio out never hands the card back.
        if let error, !failsAfterAudioLeft { throw error }

        if let onAudioLeftDevice { await onAudioLeftDevice() }
        if playbackDelay > .zero { try? await Task.sleep(for: playbackDelay) }
        if let error { throw error }

        sentPlayerIds.append(playerId)
    }
}
