import SwiftUI
import MusicAssistantKit

/// Native mini player — Apple-Music-style compact bar with horizontal paging across
/// connected players. A completed swipe calls `PlayerBarStore.selectPlayer`, mirroring
/// Compose's `HorizontalPager` + `snapshotFlow { pagerState.settledPage }.collect { selectPlayer(...) }`
/// wiring it replaces (the original lived in `ComposeScreenHosts.kt`'s `PlayerBarContent`; that
/// whole file is gone — recoverable at `e2514156`).
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

    @State private var pagerHaptic = HapticSignal()

    // Last, so callers can pass it as a trailing closure.
    let onExpand: () -> Void

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
            // Only on a real settle onto a different player. A programmatic sync (Kotlin changed
            // the selection) trips the guard above and returns before reaching this.
            pagerHaptic.fire(.selection)
        }
        .haptics(pagerHaptic)
    }

    private var currentPlayerID: String? { store.selectedPlayerID }

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

    @State private var haptic = HapticSignal()
    @State private var showPicker = false

    /// The audiobook this player is on, when that's what it's on.
    ///
    /// Its own fields beat the flattened `title`/`subtitle` the server sends in `current_media`:
    /// those describe whatever stream is open — often a per-file title with the book name
    /// nowhere in it — while the book and its author are what identify what you're listening to.
    private var audiobook: Audiobook? { player.trackItem as? Audiobook }

    /// The book, not the file, whenever there is one.
    private var titleLine: String {
        audiobook?.displayName ?? player.title ?? player.name
    }

    /// The player's name leads, ahead of the artist: in a multi-room app that's what tells you
    /// which speaker you're about to control. For a book the author takes the artist's place and
    /// the chapter follows it — "where am I" is the one thing a six-hour item needs that a track
    /// doesn't.
    private var detailLine: String {
        [player.name, audiobook?.subtitle ?? player.subtitle, chapterName]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " • ")
    }

    /// The chapter in play, for the settled page only.
    ///
    /// Kotlin resolves a chapter for the *selected* player alone — it's the only one whose
    /// boundaries are worth holding a timer for — so a neighbour page mid-swipe would otherwise
    /// be captioned with this player's chapter. It appears as the swipe settles, which is also
    /// when the rest of the bar starts speaking for the player you landed on.
    ///
    /// Nil when the server's chapter-progress preference is off, same as the expanded player's
    /// hero line: the two read the same book the same way.
    private var chapterName: String? {
        guard audiobook != nil, store.selectedPlayerID == player.id else { return nil }
        return store.presentationChapter?.name
    }

    var body: some View {
        // Only worth a long press when there's a choice to make.
        //
        // This was a `contextMenu` — long press *is* the context-menu gesture, so it came with
        // the press haptic and the lifted preview for free. The preview was the problem: it
        // renders the row outside the tab accessory it is laid out for, at a size that does not
        // match the bar, so the content visibly jumped as it lifted. Shrinking what the preview
        // sees helped and did not cure it.
        //
        // A long press opening the same sheet the expanded player uses has no preview to get
        // wrong, and makes one list the single answer to "which player" everywhere.
        inAccessory(
            card
                .onLongPressGesture(minimumDuration: 0.4) {
                    guard store.players.count > 1 else { return }
                    haptic.fire(.impact(weight: .medium))
                    showPicker = true
                }
        )
        .sheet(isPresented: $showPicker) {
            PlayerPickerSheet(player: player, store: store)
        }
    }

    /// Wraps whichever of the two the body picked. Filling the height is what actually centres
    /// the row: given a frame the size of the accessory, the content sits in the middle of it
    /// rather than wherever a smaller child happens to be placed. The content shape then makes a
    /// tap anywhere on the pill expand, not only one on the content itself.
    private func inAccessory(_ content: some View) -> some View {
        content
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture { onExpand() }
            .haptics(haptic)
    }

    /// What the context menu lifts, and deliberately *not* the full-height frame below it.
    ///
    /// A context-menu preview renders its view outside the accessory it normally lives in, so a
    /// `maxHeight: .infinity` in here has nothing left to resolve against and the row re-lays
    /// itself out as it lifts — which is the content visibly jumping on long press. Height is
    /// intrinsic here; filling the accessory happens one level up, where the preview never sees
    /// it.
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
            // Width only. The row still spans the pill, and a preview can resolve this against
            // whatever width it is given.
            .frame(maxWidth: .infinity)
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            ArtworkView(url: player.artworkURL, kind: .track, sizing: .fixed(36))

            // Both lines scroll themselves when they overflow — see `MarqueeText` — and the
            // group ties them to one beat: they set off together, and whichever finishes first
            // waits for the other before either starts again. Letting them free-run means the
            // title and the artist line end up sliding past each other at unrelated moments,
            // which reads as two things happening rather than one.
            MarqueeGroup {
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: titleLine)
                        .font(.subheadline.weight(.medium))
                    if !detailLine.isEmpty {
                        MarqueeText(text: detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                store.togglePlayPause(id: player.id)
                haptic.fire(.impact(weight: .medium))
            } label: {
                PlayPauseIcon(isPlaying: player.isPlaying)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Button {
                store.skipNext(id: player.id)
                haptic.fire(.impact(weight: .light))
            } label: {
                Image(systemName: "forward.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
    }
}
