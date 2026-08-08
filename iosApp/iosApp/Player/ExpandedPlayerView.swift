import SwiftUI
import ComposeApp

/// Native expanded (full-screen) player — Phase 1: hero, seek, full transport, favorite,
/// volume, swipe-between-players, swipe-down-to-dismiss. Reuses the exact `PlayerBarStore`
/// `AppTabView` already owns and passes to `MiniPlayerView` — Compose's own `ExpandedPlayerPage`
/// and `CollapsedPlayerPage` share one `HorizontalPager`/state too, just a richer per-page
/// composable, so there's no separate player list/selection to bridge here.
///
/// Deliberately **not** here yet (unreachable until a later phase builds each natively): the
/// reorderable queue list, group management, DSP settings, playback speed, lyrics, and the
/// overflow (⋮) menu (power, "don't stop the music", queue transfer, go-to-artist/album). None
/// of the underlying Kotlin/server logic is touched — only their Swift entry point is gone.
struct ExpandedPlayerView: View {

    var store: PlayerBarStore
    let onCollapse: () -> Void

    /// Fresh per presentation — matches Compose's own "fresh `PagerState` per mount, seeded
    /// from the current selection" behavior (a `.fullScreenCover` is a new view every time).
    @State private var scrollID: String?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if !store.players.isEmpty {
                pager
            }
        }
        .onAppear {
            guard scrollID == nil else { return }
            scrollID = currentPlayerID
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(store.players) { player in
                    ExpandedPlayerRow(
                        player: player,
                        store: store,
                        isSelected: player.id == scrollID,
                        onCollapse: onCollapse
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrollID)
        .onChange(of: scrollID) { _, newID in
            guard let newID, newID != currentPlayerID else { return }
            store.selectPlayer(id: newID)
        }
    }

    private var currentPlayerID: String? {
        guard store.players.indices.contains(store.selectedIndex) else { return nil }
        return store.players[store.selectedIndex].id
    }
}

private struct ExpandedPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    /// Whether this page is the one currently on screen — gates the live position
    /// subscription so only the visible page's ticker runs, not one per connected player.
    let isSelected: Bool
    let onCollapse: () -> Void

    @State private var livePosition: Double?
    @State private var positionSub: Cancellable?

    @State private var userDragPosition: Double?
    @State private var releasedSeekPosition: Double?

    @State private var volumeDragValue: Float?

    var body: some View {
        VStack(spacing: 24) {
            header
            hero
                .gesture(dismissGesture)
            seekSection
            transportRow
            favoriteAndVolumeRow
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .onAppear { updatePositionSubscription() }
        .onDisappear { positionSub?.cancel() }
        .onChange(of: isSelected) { _, _ in updatePositionSubscription() }
        .onChange(of: displayPosition) { _, newValue in
            guard let released = releasedSeekPosition else { return }
            if abs(newValue - released) < 0.5 { releasedSeekPosition = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            Text(player.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            // Balances the chevron button so the name stays visually centered.
            Image(systemName: "chevron.down").font(.title3).opacity(0)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 16) {
            SpikeArtwork(url: player.artworkURL, kind: .track, sizing: .flexible(decodeHint: 340))
                .frame(maxWidth: 340)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 12)

            VStack(spacing: 4) {
                Text(player.title ?? player.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                if let subtitle = player.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Downward fling collapses the sheet — mirrors `PlayersPager.kt`'s distance+velocity-gated
    /// `detectVerticalDragGestures` (120dp / 1000dp-per-second thresholds). SwiftUI's
    /// `DragGesture` has no direct velocity API; `predictedEndTranslation` (the system's
    /// fling-deceleration extrapolation) stands in for it — a real fling's predicted end sits
    /// well past its current position, a slow drag's doesn't. Thresholds are a starting point,
    /// expected to need on-device tuning.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if translation > 120, predicted > 250 {
                    onCollapse()
                }
            }
    }

    // MARK: - Seek

    private var displayPosition: Double {
        livePosition ?? player.elapsedTime ?? 0
    }

    private var sliderValue: Double {
        guard !player.isPoweredOff else { return 0 }
        return userDragPosition ?? releasedSeekPosition ?? displayPosition
    }

    private var duration: Double { max(player.duration ?? 0, 1) }

    private var seekSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { sliderValue }, set: { userDragPosition = $0 }),
                in: 0...duration,
                onEditingChanged: { editing in
                    guard !editing, let seekPosition = userDragPosition else { return }
                    releasedSeekPosition = seekPosition
                    store.seek(id: player.id, seconds: seekPosition)
                    userDragPosition = nil
                }
            )
            .disabled(!player.canPlay || player.isPoweredOff)

            HStack {
                Text(formattedDuration(sliderValue))
                Spacer()
                Text(formattedDuration(duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func updatePositionSubscription() {
        positionSub?.cancel()
        positionSub = nil
        guard isSelected else {
            livePosition = nil
            return
        }
        positionSub = KmpHelper.shared.observePlayerBarPosition(playerId: player.id).subscribe(
            onEach: { value in livePosition = value?.doubleValue },
            onError: { _ in }
        )
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 28) {
            Button {
                store.toggleShuffle(id: player.id)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffleEnabled ? .primary : .secondary)
            }
            .disabled(player.isDynamicPlaylist)

            Button {
                store.skipPrevious(id: player.id)
            } label: {
                Image(systemName: "backward.fill").font(.title2)
            }

            Button {
                store.togglePlayPause(id: player.id)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)

            Button {
                store.skipNext(id: player.id)
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }

            Button {
                store.cycleRepeatMode(id: player.id)
            } label: {
                Image(systemName: repeatSymbolName)
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off || player.repeatMode == nil ? .secondary : .primary)
            }
            .disabled(player.isDynamicPlaylist)
        }
        .buttonStyle(.plain)
        .disabled(!player.canPlay)
        .frame(maxWidth: .infinity)
    }

    private var repeatSymbolName: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    // MARK: - Favorite + volume

    private var canFavorite: Bool { player.trackItem?.uri != nil }
    private var isFavorite: Bool { player.trackItem?.favorite?.boolValue ?? false }

    private var favoriteAndVolumeRow: some View {
        VStack(spacing: 16) {
            if canFavorite {
                Button {
                    guard let item = player.trackItem else { return }
                    _ = KmpHelper.shared.setFavorite(item: item, favorite: !isFavorite)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.title3)
                }
            }

            if let volume = player.volumeLevel {
                HStack(spacing: 12) {
                    Button {
                        store.toggleMute(id: player.id)
                    } label: {
                        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .disabled(!player.canMute)

                    Slider(
                        value: Binding(
                            get: { volumeDragValue ?? volume },
                            set: { volumeDragValue = $0 }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            guard !editing, let level = volumeDragValue else { return }
                            store.setVolume(id: player.id, level: level)
                            volumeDragValue = nil
                        }
                    )

                    Text("\(Int((volumeDragValue ?? volume) * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

private func formattedDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}
