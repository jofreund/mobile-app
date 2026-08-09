import SwiftUI
import ComposeApp

/// Native mini player — Apple-Music-style compact bar with horizontal paging across
/// connected players. A completed swipe calls `PlayerBarStore.selectPlayer`, mirroring
/// Compose's `HorizontalPager` + `snapshotFlow { pagerState.settledPage }.collect { selectPlayer(...) }`
/// wiring it replaces (see `ComposeScreenHosts.kt`'s now-removed `PlayerBarContent` pager
/// effect for the original).
///
/// Lives in `.tabViewBottomAccessory` (see `AppTabView`), so the system owns its height and the
/// space scroll views leave for it. This view used to reserve that space itself, with a constant
/// height and a hand-rolled `.safeAreaInset`; none of that is its job any more.
///
/// There is no way to ask the accessory for a particular height — the API takes content and an
/// enabled flag, nothing else. `.tabBarMinimizeBehavior(.onScrollDown)` looked like a way around
/// that, but the `.expanded` placement it produces is *wider*, not taller: the accessory takes
/// back the collapsed tab bar's width at the same height. So the layout below works within the
/// height it's given and renders identically in both placements.
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

    /// Sizes `FloatingBarSideEffectsController`'s invisible `.background` in `AppTabView.swift`.
    /// Nothing to do with this bar's own height any more — the accessory decides that — but the
    /// host has to be given *some* size, and it fills itself with an opaque colour, so keeping
    /// it small keeps it from painting over whatever is scrolling behind it.
    static let sideEffectsHostHeight: CGFloat = 64

    /// A ceiling, never a height. The accessory proposes its own size and the content takes it,
    /// which is the whole point of letting the system own this. The cap exists only because the
    /// pager below is a horizontal `ScrollView` — greedy on both axes — and an unbounded
    /// proposal would let it grow without limit, which once ballooned the bar and stranded its
    /// card mid-screen. Well clear of either placement's real height.
    private static let maxContentHeight: CGFloat = 140

    var body: some View {
        ZStack {
            if !store.players.isEmpty {
                pager
            }
        }
        .frame(maxHeight: Self.maxContentHeight)
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
        // No padding of its own. A bottom-only 4pt used to sit here, from when the bar was a
        // floating card that needed clearance above the tab bar — inside the accessory it just
        // pushed everything 4pt off centre. The horizontal inset went the same way: the
        // accessory already insets its content, and stacking another 8pt on top of the row's
        // own held the artwork well clear of the pill's edge. Horizontal spacing now comes from
        // one place, the row itself, so it can be tuned by eye without two values compounding.
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

/// One page: artwork, what's playing, play/pause, skip-forward. Tapping elsewhere on the row
/// expands — mirrors `FloatingBar.kt`'s tap-anywhere-to-expand-when-collapsed.
///
/// Deliberately renders the same in both accessory placements. Minimising the tab bar turns out
/// to widen the accessory rather than heighten it — `.expanded` shares the row with a collapsed
/// tab bar and reclaims its width — so there is no extra vertical room to spend, and a layout
/// that changed shape between the two just made the transition jump.
///
/// Draws no background of its own. The accessory supplies the pill and its material; an inner
/// card meant a second, differently-rounded shape sitting inside it that couldn't fill the
/// corners, which read as a grey block that didn't reach the edges.
private struct MiniPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    let onExpand: () -> Void

    /// The player's name leads, ahead of the artist: in a multi-room app that's what tells you
    /// which speaker you're about to control.
    private var detailLine: String {
        [player.name, player.subtitle]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " • ")
    }

    var body: some View {
        // Only worth a long press when there's a choice to make. An unconditional
        // `.contextMenu` would still trigger on a single-player setup and open an empty menu.
        if store.players.count > 1 {
            // Long press *is* the context menu gesture on iOS, so this brings the press-and-hold
            // haptic and the lifted preview with it, and needs no gesture of its own to fight
            // the pager's horizontal drag. Same content as the expanded player's header menu.
            card.contextMenu { PlayerPickerMenu(store: store, currentId: player.id) }
        } else {
            card
        }
    }

    private var card: some View {
        mainRow
            .padding(.horizontal, 18)
            // Vertical padding is nearly cosmetic here, and that's worth knowing before
            // reaching for it: the row is centred in a fixed-height accessory, so the gap above
            // and below the artwork is (accessory height − artwork) / 2 whatever this is set
            // to. Padding only eats the slack it's centred in. Breathing room above and below
            // comes from the artwork size instead. Kept small as headroom against clipping —
            // an earlier 40pt artwork with 12pt of padding overran the accessory and cut off
            // the second line of text.
            .padding(.vertical, 4)
            // Filling the height is what actually centres the row: given a frame the size of
            // the accessory, the content sits in the middle of it rather than wherever a
            // smaller child happens to be placed.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Fills the accessory, so a tap anywhere on the pill expands rather than only on
            // the content itself.
            .contentShape(.rect)
            .onTapGesture { onExpand() }
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            SpikeArtwork(url: player.artworkURL, kind: .track, sizing: .fixed(36))

            VStack(alignment: .leading, spacing: 1) {
                Text(player.title ?? player.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !detailLine.isEmpty {
                    Text(detailLine)
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
    }
}
