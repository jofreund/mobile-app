import Foundation
import MusicAssistantKit

/// Brings up the local (Sendspin) player's Swift half — the AudioQueue sink and the Now
/// Playing owner — only once the feature is switched on, and never before.
///
/// Both used to be created in `iOSApp.init` unconditionally. That cost every launch an
/// `AVAudioSession` category change, remote-command registration and three channel
/// subscriptions for a feature that is off by default, and it put the app on the audio session
/// before it had any audio to play. Now the stack comes up when `sendspinEnabled` is already
/// true at launch, or the moment it flips to true, and then stays up for the rest of the
/// process: the Kotlin side stops the Sendspin client when the toggle goes off, and an idle sink
/// costs nothing.
///
/// Ordering with Kotlin: `MediaPlayerController.prepareStream` resolves the sink through
/// `PlatformPlayerProvider` and reports an error rather than dropping audio silently if nothing
/// is registered. Registration here runs on the main thread — synchronously in `start()` when
/// the setting is already on, otherwise from the setting's own emission — and a Sendspin
/// handshake takes far longer than either before its first stream can arrive.
@MainActor
final class LocalPlayerActivation {

    private var audio: NativeAudioController?
    private var subscription: Cancellable?

    /// Call once, after `bootstrapKmp()` — it reads the Kotlin settings graph.
    func start() {
        guard subscription == nil else { return }
        if KmpHelper.shared.sendspinEnabled.value?.boolValue == true {
            activate()
        }
        subscription = KmpHelper.shared.sendspinEnabled.subscribe { [weak self] enabled in
            guard enabled?.boolValue == true else { return }
            self?.activate()
        }
    }

    private func activate() {
        guard audio == nil else { return }
        let controller = NativeAudioController()
        audio = controller
        // Register the sink first, so a stream that lands between these two lines has somewhere
        // to go. Creating the shared coordinator configures the audio session and the remote
        // commands; observing subscribes it to the Kotlin now-playing channels.
        PlatformPlayerProvider.shared.player = controller
        NowPlayingCoordinator.shared.startObserving()
    }
}
