import ActivityKit
import Foundation
import MusicAssistantKit
import UIKit

/// Owns the one lock screen / Dynamic Island Live Activity that mirrors the *selected* player —
/// subscribes to `KmpHelper.playerBarState` (its own subscription, deliberately independent of
/// `PlayerBarStore`, which lives and dies with `AppTabView`) and starts, updates, and ends the
/// activity as that state changes.
///
/// Lifecycle facts this class is shaped around:
///  - `Activity.request` only works while the app is foregrounded (there is no push-to-start
///    here — the MA server will never send APNs), so creation is gated on `isForeground`;
///    `update`/`end` work whenever the process is running, which includes the background
///    execution window a `LiveActivityIntent` opens.
///  - Once the app suspends, nothing can update the activity, so state changes made from other
///    MA clients go unseen. Every publish therefore carries a `staleDate`; the widget renders a
///    stale marker instead of confidently wrong transport state.
///  - After a cold background launch (intent tap), the previous run's activity is still on the
///    lock screen. It is adopted, never ended-and-recreated — ending it would tear down the very
///    UI the user is holding.
@MainActor
final class PlayerActivityController {

    private var stateSub: Cancellable?
    private var localTrackSub: Cancellable?
    private var isForeground = false
    private var activity: Activity<PlayerActivityAttributes>?

    /// True while the local (Sendspin) player has something to present. The system's own
    /// Now Playing surface (fed by `NowPlayingCoordinator` off the real audio session) owns
    /// the lock screen then; publishing a Live Activity beside it would show two competing
    /// cards for the same playback. Exactly one of the two drives the lock screen at a time.
    private var localPlayerPresents = false

    /// Last content published, to skip no-op republishes (playerBarState emits on every volume
    /// echo and position anchor; ActivityKit updates are not free).
    private var lastPublished: PlayerActivityAttributes.ContentState?

    /// The artwork URL whose downscaled copy currently sits in the app-group container, and the
    /// file it sits in. Compared by URL string so a track change with identical art (album
    /// playback) skips the reload-and-rewrite entirely.
    private var artworkUrlOnDisk: String?
    private var artworkFileName: String?
    private var artworkLoadTask: Task<Void, Never>?

    /// How long the shown transport state is trusted once updates stop. 30 minutes keeps a
    /// paused-audiobook activity useful for an evening without claiming all-night accuracy.
    private static let staleInterval: TimeInterval = 30 * 60

    /// Pixel edge for the shared artwork file — the widget renders at most ~60 pt (@3x ≈ 180 px).
    private static let artworkMaxPixel: CGFloat = 256

    func start() {
        guard stateSub == nil else { return }
        // Adopt the surviving activity from a previous run (a background intent launch must
        // update the very card being tapped, not replace it); end any extras defensively —
        // there should never be more than one, but a duplicate would linger 8 hours.
        let existing = Activity<PlayerActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        stateSub = KmpHelper.shared.playerBarState.subscribe { [weak self] state in
            self?.handle(state)
        }
        localTrackSub = KmpHelper.shared.observeNowPlayingTrack { [weak self] track in
            guard let self else { return }
            let presents = track != nil
            guard presents != self.localPlayerPresents else { return }
            self.localPlayerPresents = presents
            // Stand down when the local player takes the lock screen; re-sync from the
            // current bar state when it lets go.
            self.handle(KmpHelper.shared.playerBarState.value)
        }
    }

    func scenePhaseChanged(active: Bool) {
        isForeground = active
        if active {
            // A request skipped while backgrounded has no later trigger of its own — re-run the
            // sync against the current value now that requesting is allowed.
            handle(KmpHelper.shared.playerBarState.value)
        }
    }

    // MARK: - State → activity

    private func handle(_ state: PlayerBarState?) {
        guard !localPlayerPresents, let content = Self.desiredContent(from: state) else {
            endActivity()
            return
        }
        publish(content)
    }

    /// The content the activity should show for this state, or nil when there is nothing to
    /// show (no players, or the selected player has no current item — an idle player's activity
    /// would be an inert card with a dead button).
    private static func desiredContent(from state: PlayerBarState?) -> PlayerActivityAttributes.ContentState? {
        guard let data = state as? PlayerBarState.Data,
              !data.players.isEmpty else { return nil }
        let index = Int(data.selectedIndex)
        guard index >= 0, index < data.players.count else { return nil }
        let item = data.players[index]
        guard let title = item.title, !title.isEmpty, !item.isPoweredOff else { return nil }
        return PlayerActivityAttributes.ContentState(
            playerId: item.playerId,
            playerName: item.name,
            title: title,
            subtitle: item.subtitle,
            isPlaying: item.isPlaying,
            artworkFileName: nil // filled in by publish() from the artwork bookkeeping
        )
    }

    private func publish(_ desired: PlayerActivityAttributes.ContentState) {
        // Track before mutating: the artwork fields compare against what the *selected* item
        // wants now, not against what was last published.
        let wantedArtworkUrl = currentArtworkUrl()
        var content = desired
        content.artworkFileName = (wantedArtworkUrl == artworkUrlOnDisk) ? artworkFileName : nil

        if content != lastPublished {
            lastPublished = content
            let activityContent = ActivityContent(
                state: content,
                staleDate: Date().addingTimeInterval(Self.staleInterval)
            )
            // `.stale` still accepts updates — and updating is how it returns to `.active`.
            // Requesting a second activity while a stale one lives would stack duplicates.
            if let activity, activity.activityState == .active || activity.activityState == .stale {
                Task { await activity.update(activityContent) }
            } else if isForeground, ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(
                    attributes: PlayerActivityAttributes(),
                    content: activityContent
                )
            }
        }

        if let wantedArtworkUrl, wantedArtworkUrl != artworkUrlOnDisk {
            loadArtwork(urlString: wantedArtworkUrl)
        }
    }

    /// The selected player's artwork URL straight from the current Kotlin state — read at
    /// publish time rather than threaded through `desiredContent`, since it feeds the side
    /// channel (the app-group file), not the content diff.
    private func currentArtworkUrl() -> String? {
        guard let data = KmpHelper.shared.playerBarState.value as? PlayerBarState.Data else { return nil }
        let index = Int(data.selectedIndex)
        guard index >= 0, index < data.players.count else { return nil }
        return data.players[index].artworkUrl
    }

    private func loadArtwork(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        artworkLoadTask?.cancel()
        artworkLoadTask = Task { [weak self] in
            guard let image = await ArtworkLoader.shared.image(for: url, maxPixel: Self.artworkMaxPixel),
                  !Task.isCancelled,
                  let self else { return }
            guard let fileName = Self.writeArtwork(image, for: urlString) else { return }
            let previous = self.artworkFileName
            self.artworkUrlOnDisk = urlString
            self.artworkFileName = fileName
            if let previous, previous != fileName, let stale = PlayerActivityArtworkStore.url(for: previous) {
                try? FileManager.default.removeItem(at: stale)
            }
            // Republish with the artwork attached. Force the diff: the visible fields are
            // unchanged, only the file name is new.
            if var content = self.lastPublished {
                content.artworkFileName = fileName
                self.lastPublished = nil
                self.publishCurrentIfStillWanted(content)
            }
        }
    }

    /// Re-checks against live state before republishing artwork — the track may have changed
    /// again while the image was loading.
    private func publishCurrentIfStillWanted(_ content: PlayerActivityAttributes.ContentState) {
        guard let desired = Self.desiredContent(from: KmpHelper.shared.playerBarState.value),
              desired.playerId == content.playerId, desired.title == content.title else {
            handle(KmpHelper.shared.playerBarState.value)
            return
        }
        publish(desired)
    }

    /// FNV-1a over the URL string — NOT `String.hashValue`, which is seeded per process, so
    /// nothing written by one launch would be findable by the next (same trap ArtworkDiskCache
    /// documents). Alpha-bearing art (SVG-rendered genre tiles) goes out as PNG so it isn't
    /// flattened onto black; opaque covers as JPEG.
    private static func writeArtwork(_ image: UIImage, for urlString: String) -> String? {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hasAlpha: Bool
        switch image.cgImage?.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            hasAlpha = true
        default:
            hasAlpha = false
        }
        let fileName = "activity-artwork-\(String(hash, radix: 16)).\(hasAlpha ? "png" : "jpg")"
        guard let target = PlayerActivityArtworkStore.url(for: fileName),
              let data = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.8)
        else { return nil }
        do {
            try data.write(to: target, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func endActivity() {
        lastPublished = nil
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

// MARK: - Intent execution (app process)

/// The app-process half of `PlayerPlayPauseIntent.perform()`. Kept out of the shared file so the
/// widget extension never sees a MusicAssistantKit import.
enum PlayerActivityCommand {
    /// Main-actor because `UIApplication.applicationState` demands it and every KmpHelper
    /// surface in this codebase is driven from the main thread; the intent's `perform()`
    /// arrives on an arbitrary executor.
    @MainActor
    static func togglePlayPause(playerId: String) async {
        guard KmpState.isReady else { return }
        let wasBackground = UIApplication.shared.applicationState == .background

        let sent: Bool = await withCheckedContinuation { continuation in
            KmpHelper.shared.systemTogglePlayPause(playerId: playerId) { accepted in
                continuation.resume(returning: accepted.boolValue)
            }
        }

        // systemTogglePlayPause poked onAppForeground so a backgrounded socket would reconnect;
        // if no scene actually came to the foreground, restore the flag so the client's
        // background bookkeeping stays truthful. Cheap either way — it only sets state.
        if wasBackground {
            KmpHelper.shared.onAppBackground()
        }

        // Hold the intent open briefly after a successful send: the optimistic play-state
        // override has already flipped playerBarState, and the controller's activity update
        // rides that emission — but `perform()` returning is the system's cue that it may
        // suspend the process, so give the update a moment to reach ActivityKit.
        if sent {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
}
