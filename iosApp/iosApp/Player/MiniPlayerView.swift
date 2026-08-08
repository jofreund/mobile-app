import SwiftUI
import ComposeApp

/// Native mini player — Apple-Music-style compact bar with horizontal paging across
/// connected players. A completed swipe calls `PlayerBarStore.selectPlayer`, mirroring
/// Compose's `HorizontalPager` + `snapshotFlow { pagerState.settledPage }.collect { selectPlayer(...) }`
/// wiring it replaces (see `ComposeScreenHosts.kt`'s now-removed `PlayerBarContent` pager
/// effect for the original). Renders nothing when there are no connected players, so the tab
/// reclaims full height — matching the Compose original's "renders nothing when not
/// Data+non-empty" behavior.
///
/// Volume/shuffle/repeat/seek and the expanded (full-screen) player are intentionally not
/// here — this is the *collapsed* bar only; tapping it opens the still-Compose-hosted expanded
/// player via `onExpand`, unchanged.
struct MiniPlayerView: View {

    var store: PlayerBarStore
    let onExpand: () -> Void

    @State private var scrollID: String?

    var body: some View {
        Group {
            if store.players.isEmpty {
                EmptyView()
            } else {
                pager
            }
        }
    }

    private var pager: some View {
        VStack(spacing: 2) {
            if let name = visiblePlayerName {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(store.players) { player in
                        MiniPlayerRow(player: player, store: store, onExpand: onExpand)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrollID)
            .frame(height: 64)
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 4)
        .onAppear { syncScrollToSelection() }
        .onChange(of: store.selectedIndex) { _, _ in syncScrollToSelection() }
        .onChange(of: scrollID) { _, newID in
            // Whether this fires only on settle or continuously during a drag is an
            // open on-device question (flagged in the implementation plan) — if it
            // turns out to fire mid-drag, this would call selectPlayer too eagerly and
            // the fallback is `TabView(selection:).tabViewStyle(.page(...))` instead.
            guard let newID, newID != currentPlayerID else { return }
            store.selectPlayer(id: newID)
        }
    }

    private var currentPlayerID: String? {
        guard store.players.indices.contains(store.selectedIndex) else { return nil }
        return store.players[store.selectedIndex].id
    }

    /// The name label above the bar — mirrors Compose's `PlayerSelectionButton`, shown above
    /// `CompactPlayerItem` in `CollapsedPlayerPage`. Tracks `scrollID` (what's actually on
    /// screen right now) rather than `store.selectedIndex` (the Kotlin-confirmed selection,
    /// which only updates once a swipe settles and round-trips through the bridge), so the
    /// name updates in step with the swipe instead of lagging a beat behind it.
    private var visiblePlayerName: String? {
        (store.players.first { $0.id == scrollID } ?? store.players[safe: store.selectedIndex])?.name
    }

    /// Pushes a Kotlin-driven selection change into the scroll position — the counterpart to
    /// Compose's `animateScrollToPage(target)`, guarded the same way (only acts when the
    /// target actually differs) to avoid fighting an in-progress user drag.
    private func syncScrollToSelection() {
        guard let targetID = currentPlayerID, targetID != scrollID else { return }
        withAnimation(.easeOut(duration: 0.25)) { scrollID = targetID }
    }
}

/// One page: artwork, title/artist, play/pause, skip-forward. Tapping elsewhere on the row
/// expands — mirrors `FloatingBar.kt`'s tap-anywhere-to-expand-when-collapsed.
private struct MiniPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SpikeArtwork(url: player.artworkURL, kind: .track, sizing: .fixed(48))

            VStack(alignment: .leading, spacing: 2) {
                Text(player.title ?? player.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let subtitle = player.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                store.togglePlayPause(id: player.id)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button {
                store.skipNext(id: player.id)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onExpand() }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
