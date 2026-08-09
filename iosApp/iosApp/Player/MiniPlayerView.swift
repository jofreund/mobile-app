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
/// It renders at two sizes, following `\.tabViewBottomAccessoryPlacement`: `.inline` alongside
/// the tab bar, and the taller `.expanded` the system gives it when the tab bar minimises away
/// on scroll. There is no way to ask for a specific height — the accessory API takes content and
/// an enabled flag, nothing else — so `.expanded` is the only route to a roomier bar.
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
    /// card mid-screen. Generous enough to clear the `.expanded` placement, which is taller
    /// than `.inline` by roughly the tab bar it replaces.
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

/// One page: artwork, what's playing, play/pause, skip-forward. Tapping elsewhere on the row
/// expands — mirrors `FloatingBar.kt`'s tap-anywhere-to-expand-when-collapsed.
///
/// Renders two ways, following the accessory's own placement. `.inline` shares the row with the
/// tab bar and is short, so the player's name rides on the detail line. `.expanded` — which the
/// system hands us when the tab bar minimises away on scroll — has about a tab bar's worth of
/// extra height, and spends it putting that name back on its own line, as it was before the bar
/// moved into the accessory.
private struct MiniPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    let onExpand: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isExpanded: Bool { placement == .expanded }

    /// Inline has no room for the player's name of its own, so it leads the detail line —
    /// ahead of the artist, because in a multi-room app that's what tells you which speaker
    /// you're about to control. Expanded shows it above instead, leaving this to the artist.
    private var detailLine: String {
        let parts = isExpanded ? [player.subtitle] : [player.name, player.subtitle]
        return parts
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isExpanded {
                Text(player.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            mainRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 8 : 6)
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

    private var mainRow: some View {
        HStack(spacing: 10) {
            SpikeArtwork(url: player.artworkURL, kind: .track, sizing: .fixed(isExpanded ? 48 : 40))

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
