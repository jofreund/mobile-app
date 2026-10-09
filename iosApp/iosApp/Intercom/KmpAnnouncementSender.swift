import Foundation
import MusicAssistantKit
import UIKit

/// ``AnnouncementSending`` over the Kotlin kernel: reads the recording's rate and
/// audio and hands the audio to `KmpHelper.sendRecordedAnnouncement`, which
/// streams it over the live-announcement socket (direct) or data channel
/// (remote access).
///
/// Kept out of the view model's file so the view model and its tests never
/// import `MusicAssistantKit`.
struct KmpAnnouncementSender: AnnouncementSending {
    @MainActor
    func send(clip: URL, to playerId: String, onAudioLeftDevice: (@MainActor @Sendable () -> Void)?) async throws {
        // A minute of audio is a few megabytes; read it off the main actor,
        // which at this moment is springing the pop-over back onto its tile.
        let (sampleRate, pcm) = try await Task.detached(priority: .userInitiated) { () throws -> (Int, Data) in
            guard let format = try WAVFile.format(of: clip),
                  format.channels == IntercomAudioFormat.channels,
                  format.bitDepth == IntercomAudioFormat.bitDepth,
                  let pcm = try WAVFile.pcmData(of: clip),
                  !pcm.isEmpty
            else { throw AnnouncementError.notSent(reason: nil) }
            return (format.sampleRate, pcm)
        }.value

        // The kernel streams the clip from here on; the app going away
        // half-way through would have the server play the half that arrived.
        // Held until the result, which comes once the clip has played.
        let backgroundTask = SendBackgroundTask(name: "Intercom announcement")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            KmpHelper.shared.sendRecordedAnnouncement(
                playerId: playerId,
                pcm: pcm,
                sampleRate: Int32(sampleRate),
                onAudioLeftDevice: {
                    // Kotlin delivers both callbacks on the main thread.
                    MainActor.assumeIsolated { onAudioLeftDevice?() }
                },
                onResult: { result in
                    MainActor.assumeIsolated { backgroundTask.end() }
                    if let error = AnnouncementError.from(
                        played: result.played,
                        reason: result.reason,
                        audioSent: result.audioSent,
                        stopSent: result.stopSent
                    ) {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}

/// Asks iOS for time to finish a send the user has already let go of.
@MainActor
private final class SendBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: what has not gone out by now is not going out.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
