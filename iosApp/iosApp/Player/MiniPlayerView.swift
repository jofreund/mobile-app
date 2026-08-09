import SwiftUI
import ComposeApp

/// Native mini player — Apple-Music-style compact bar with horizontal paging across
/// connected players. A completed swipe calls `PlayerBarStore.selectPlayer`, mirroring
/// Compose's `HorizontalPager` + `snapshotFlow { pagerState.settledPage }.collect { selectPlayer(...) }`
/// wiring it replaces (see `ComposeScreenHosts.kt`'s now-removed `PlayerBarContent` pager
/// effect for the original).
///
/// Reserves [reservedHeight] unconditionally — even before `store.players` is populated —
/// rather than collapsing to zero height while empty. `.safeAreaInset`'s reserved space is
/// supposed to track its content's size dynamically, but with `store.players` arriving a beat
/// after first layout (an async Kotlin subscription), the reserve was observed getting stuck
/// at its original zero-height measurement, leaving scrollable content underneath (e.g.
/// `HomeView`'s carousels) clipped by the mini player once it appeared. A constant height
/// sidesteps that regardless of the exact cause, matching the original Compose host's own
/// always-100pt-regardless-of-content behavior.
///
/// This is the *collapsed* bar only, styled after Apple Music's mini player — no volume/
/// shuffle/repeat/seek here; tapping it opens `ExpandedPlayerView.swift` via `onExpand`, which
/// has the full transport set.
struct MiniPlayerView: View {

    var store: PlayerBarStore
    let onExpand: () -> Void

    @State private var scrollID: String?

    /// Sized to what `MiniPlayerRow` actually draws, which is roughly:
    /// the player-name line (~17) + `VStack` spacing (6) + the artwork row (48) + the row's
    /// vertical padding (2 × 8) + the pager's bottom padding (4) ≈ 91. Rounded up to 92 so the
    /// card is never trimmed by its own frame. Recompute this if that row changes shape.
    ///
    /// It has to stay a *fixed* height rather than a minimum: the pager inside is a horizontal
    /// `ScrollView`, and a `ScrollView` is greedy on both axes, so a `minHeight` lets it grow
    /// to whatever height it's offered — which balloons the bar and strands its card in the
    /// middle of the screen (tried, reverted). The cost of pinning it is that very large
    /// Dynamic Type sizes will crop the name line.
    ///
    /// `AppTabView.swift` also sizes `FloatingBarSideEffectsController`'s `.background` from
    /// this — that background is `.background(alignment: .bottom)`'d onto the *same* view this
    /// reserves space on, so if it were ever taller, the excess would bleed upward past the
    /// reserved region and its opaque Compose backdrop would paint over the bottom slice of
    /// whatever's scrolling underneath (a real bug, fixed once already — keep them equal).
    static let reservedHeight: CGFloat = 92

    var body: some View {
        ZStack {
            if !store.players.isEmpty {
                pager
            }
        }
        .frame(height: Self.reservedHeight)
    }

    private var pager: some View {
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
        .padding(.horizontal, 8)
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

    /// Pushes a Kotlin-driven selection change into the scroll position — the counterpart to
    /// Compose's `animateScrollToPage(target)`, guarded the same way (only acts when the
    /// target actually differs) to avoid fighting an in-progress user drag.
    private func syncScrollToSelection() {
        guard let targetID = currentPlayerID, targetID != scrollID else { return }
        withAnimation(.easeOut(duration: 0.25)) { scrollID = targetID }
    }
}

/// One page: the player's name (mirrors Compose's `PlayerSelectionButton`, shown above
/// `CompactPlayerItem` in `CollapsedPlayerPage` — here it's part of the same card rather than
/// floating above it), then artwork, title/artist, play/pause, skip-forward. Tapping elsewhere
/// on the row expands — mirrors `FloatingBar.kt`'s tap-anywhere-to-expand-when-collapsed.
private struct MiniPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(player.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Hairline edge, as Apple Music's mini player has: over busy artwork the material alone
        // leaves the card's boundary indistinct. `strokeBorder` insets the line so it sits
        // inside the shape instead of straddling it and reading as double-width.
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onExpand() }
    }
}
