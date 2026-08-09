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

    /// Owned by `AppTabView`, not by this view. The accessory's content is rebuilt as tabs
    /// change, and a `@State` here went back to nil with it — the pager snapped to the first
    /// player and then animated across to the selected one, which is the scroll-and-flicker on
    /// every tab switch. Held above, it simply stays where it was.
    @Binding var scrollID: String?

    // Last, so callers can pass it as a trailing closure.
    let onExpand: () -> Void

    /// An upper bound, not a height. `.tabViewBottomAccessory` decides how tall the bar is;
    /// forcing this value inside it simply pushed the row past the accessory's bounds and got
    /// the top of the content clipped. A *maximum* still pins the one thing that must stay
    /// pinned: the pager below is a horizontal `ScrollView`, greedy on both axes, so without a
    /// ceiling it grows into whatever it's offered — which once ballooned the bar and stranded
    /// its card mid-screen (tried, reverted).
    ///
    /// `AppTabView.swift` also sizes `FloatingBarSideEffectsController`'s invisible `.background`
    /// from this. That host fills itself with an opaque colour, so it must never be taller than
    /// the bar it hides behind, or it paints over whatever is scrolling underneath (a real bug,
    /// fixed once already). A ceiling keeps it at or below, which is the safe direction.
    static let reservedHeight: CGFloat = 92

    var body: some View {
        ZStack {
            if !store.players.isEmpty {
                pager
            }
        }
        .frame(maxHeight: Self.reservedHeight)
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
        .onAppear { syncScrollToSelection(animated: false) }
        .onChange(of: store.selectedIndex) { _, _ in syncScrollToSelection(animated: true) }
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
    private func syncScrollToSelection(animated: Bool) {
        guard let targetID = currentPlayerID, targetID != scrollID else { return }
        guard animated else {
            // Appearing at the right player is not a transition to watch.
            scrollID = targetID
            return
        }
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

    /// Which player this is, ahead of who made the track — in a multi-room app that's the line
    /// that tells you what you're about to control, and it used to sit on its own row above.
    /// The accessory isn't tall enough for three lines, and that row was the one being clipped.
    private var secondLine: String {
        [player.name, player.subtitle]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 10) {
            SpikeArtwork(url: player.artworkURL, kind: .track, sizing: .fixed(40))

            VStack(alignment: .leading, spacing: 1) {
                Text(player.title ?? player.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !secondLine.isEmpty {
                    Text(secondLine)
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
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Button {
                store.skipNext(id: player.id)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
