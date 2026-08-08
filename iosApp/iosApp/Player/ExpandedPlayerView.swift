import SwiftUI
import ComposeApp

/// Native expanded (full-screen) player — Phase 1: hero, seek, full transport, volume,
/// swipe-between-players (plus a quick-switch popover from tapping the player name), and
/// swipe-down-to-dismiss. Reuses the exact `PlayerBarStore` `AppTabView` already owns and
/// passes to `MiniPlayerView` — Compose's own `ExpandedPlayerPage` and `CollapsedPlayerPage`
/// share one `HorizontalPager`/state too, just a richer per-page composable, so there's no
/// separate player list/selection to bridge here.
///
/// The queue list (tap-to-play, drag-to-reorder via native `List.onMove`, long-press via the
/// shared `ItemContextMenu.swift` plus a queue-specific "Delete", chapter rows nested under the
/// current audiobook item, auto-scroll-to-current) is also here — toggled from the header,
/// styled after Apple Music: the hero shrinks to a small peek row and the queue fills the space
/// between it and the seek/transport/volume controls, which stay pinned and usable throughout
/// rather than being replaced the way Compose's `CollapsibleQueue` replaces the whole hero.
///
/// Deliberately **not** here yet (unreachable until a later phase builds each natively):
/// favoriting (moving to the overflow menu, not staying in the always-visible hero row), group
/// management, DSP settings, playback speed, lyrics, and the rest of the overflow (⋮) menu
/// (power, "don't stop the music", queue transfer, go-to-artist/album). None of the underlying
/// Kotlin/server logic is touched — only their Swift entry point is gone.
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
        .onChange(of: store.selectedIndex) { _, _ in syncScrollToSelection() }
        .onChange(of: scrollID) { _, newID in
            guard let newID, newID != currentPlayerID else { return }
            store.selectPlayer(id: newID)
        }
    }

    private var currentPlayerID: String? {
        guard store.players.indices.contains(store.selectedIndex) else { return nil }
        return store.players[store.selectedIndex].id
    }

    /// Picking a player from the popover list only calls `store.selectPlayer` — this pushes
    /// that Kotlin-driven change into the scroll position, the counterpart to `MiniPlayerView`'s
    /// own `syncScrollToSelection` (a swipe here calls `selectPlayer` too, but that round-trips
    /// back to the same `selectedIndex` it just set, so the guard below no-ops for that path).
    private func syncScrollToSelection() {
        guard let targetID = currentPlayerID, targetID != scrollID else { return }
        withAnimation(.easeOut(duration: 0.25)) { scrollID = targetID }
    }
}

/// The popover shown from tapping the player name in the header — every connected player,
/// tap to switch. Mirrors Compose's `SelectPlayerDialog` minus reordering (deferred; this is
/// the "quick switch" affordance, not full player management).
private struct PlayerPickerList: View {

    let store: PlayerBarStore
    let currentId: String
    let onSelect: () -> Void

    var body: some View {
        List(store.players) { player in
            Button {
                store.selectPlayer(id: player.id)
                onSelect()
            } label: {
                HStack {
                    Text(player.name)
                    Spacer()
                    if player.id == currentId {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.plain)
        .frame(minWidth: 260, idealHeight: 320)
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
    @State private var showPlayerPicker = false

    @State private var showQueue = false
    /// Optimistic local reorder — reset to `nil` (falling back to `player.queueItems`' own
    /// order) whenever the Kotlin-driven order changes, mirroring Compose's
    /// `remember(items) { mutableStateOf(items) }` reset-on-server-echo.
    @State private var displayOrder: [String]?

    var body: some View {
        VStack(spacing: showQueue ? 16 : 24) {
            header
            if showQueue {
                peekRow
                queueSection
            } else {
                hero
                    .gesture(dismissGesture)
            }
            seekSection
            transportRow
            volumeRow
            if !showQueue {
                Spacer(minLength: 0)
            }
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
        .onChange(of: player.queueItems.map(\.id)) { _, _ in displayOrder = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            Button {
                showPlayerPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(player.name)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .popover(isPresented: $showPlayerPicker) {
                PlayerPickerList(store: store, currentId: player.id) {
                    showPlayerPicker = false
                }
                .presentationCompactAdaptation(.popover)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showQueue.toggle() }
            } label: {
                Image(systemName: showQueue ? "list.bullet.circle.fill" : "list.bullet.circle")
                    .font(.title3)
            }
            .accessibilityLabel(String(localized: "cd_toggle_queue"))
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

    // MARK: - Queue

    /// The compact top row shown in place of the big hero while the queue is visible — matches
    /// the Apple Music screenshot the queue design is based on.
    private var peekRow: some View {
        HStack(spacing: 12) {
            SpikeArtwork(url: player.artworkURL, kind: .track, sizing: .fixed(48))
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title ?? player.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = player.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Local order (falling back to Kotlin's own order) — `displayOrder` only ever holds ids,
    /// reconciled against `player.queueItems` so a stale id (already removed server-side)
    /// can't produce a crash; if the two have drifted in *count* (an add/remove landed while a
    /// drag was in flight), just fall back to the fresh server order outright.
    private var orderedQueueItems: [QueueBarItemView] {
        guard let order = displayOrder else { return player.queueItems }
        let byId = Dictionary(uniqueKeysWithValues: player.queueItems.map { ($0.id, $0) })
        let ordered = order.compactMap { byId[$0] }
        return ordered.count == player.queueItems.count ? ordered : player.queueItems
    }

    private var currentQueueIndex: Int? {
        orderedQueueItems.firstIndex { $0.id == player.currentQueueItemId }
    }

    @ViewBuilder
    private var queueSection: some View {
        let rows = QueueDisplayRow.build(items: orderedQueueItems, currentId: player.currentQueueItemId, chapters: player.currentItemChapters)
        if rows.isEmpty {
            emptyQueueState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(rows) { row in
                        queueRowView(row)
                    }
                    .onMove { from, to in handleMove(rows: rows, from: from, to: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
                .onChange(of: player.currentQueueItemId) { _, _ in scrollToCurrent(proxy: proxy, animated: true) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func queueRowView(_ row: QueueDisplayRow) -> some View {
        switch row {
        case .track(let item, let queueIndex):
            queueTrackRow(item, queueIndex: queueIndex)
        case .chapter(let chapter, _):
            queueChapterRow(chapter)
        }
    }

    private func queueTrackRow(_ item: QueueBarItemView, queueIndex: Int) -> some View {
        let isCurrent = item.id == player.currentQueueItemId
        let isPlayed = currentQueueIndex.map { queueIndex < $0 } ?? false
        // Mirrors Compose's exact long-press/reorder gating: only upcoming, playable,
        // non-current rows get either affordance.
        let canInteract = item.isPlayable && !isCurrent && !isPlayed

        return HStack(spacing: 12) {
            SpikeArtwork(url: item.artworkURL, kind: .track, sizing: .fixed(40))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    Text(item.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                }
                if item.isPlayable {
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(String(localized: "queue_cannot_play"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(!item.isPlayable ? 0.3 : (isPlayed ? 0.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCurrent, item.isPlayable, let queueId = player.queueId else { return }
            store.playQueueItem(queueId: queueId, queueItemId: item.id)
        }
        .moveDisabled(!canInteract)
        .modifier(QueueRowContextMenu(item: item, queueId: player.queueId, enabled: canInteract))
        .listRowBackground(Color.clear)
    }

    private func queueChapterRow(_ chapter: Chapter) -> some View {
        HStack {
            Text(chapter.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            if chapter.duration > 0 {
                Text(formattedDuration(chapter.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 52)
        .contentShape(Rectangle())
        .onTapGesture {
            store.seek(id: player.id, seconds: chapter.start.rounded(.up))
        }
        .moveDisabled(true)
        .listRowBackground(Color.clear)
    }

    /// Resolves the flattened display move into a queue-index move, mirroring
    /// `queueIndexAt`/the `toQueueIndex <= currentIdx` reject-guard from `CollapsibleQueue.kt`,
    /// then applies it optimistically to `displayOrder` before dispatching.
    private func handleMove(rows: [QueueDisplayRow], from: IndexSet, to: Int) {
        guard let fromDisplayIndex = from.first, from.count == 1 else { return }
        guard case let .track(fromItem, fromQueueIndex) = rows[fromDisplayIndex] else { return }
        guard let currentIndex = currentQueueIndex, let queueId = player.queueId else { return }

        let toQueueIndex = rows.prefix(to).reduce(0) { count, row in
            if case .track = row { count + 1 } else { count }
        }
        guard toQueueIndex > currentIndex else { return }

        var order = displayOrder ?? orderedQueueItems.map(\.id)
        order.move(fromOffsets: IndexSet(integer: fromQueueIndex), toOffset: toQueueIndex)
        displayOrder = order

        store.moveQueueItem(queueId: queueId, queueItemId: fromItem.id, from: fromQueueIndex, to: toQueueIndex)
    }

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard let currentId = player.currentQueueItemId else { return }
        let targetID = "queue:\(currentId)"
        if animated {
            withAnimation { proxy.scrollTo(targetID, anchor: .center) }
        } else {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    private var emptyQueueState: some View {
        VStack(spacing: 12) {
            Text(String(localized: "queue_empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(String(localized: "queue_browse_library")) {
                onCollapse()
                KmpHelper.shared.requestHome()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Volume
    //
    // Favoriting was here too, but removed for now — it'll come back as an overflow-menu entry
    // once that's built (matches Compose's own PlayerOverflowMenu, not the always-visible hero
    // row), rather than staying here permanently. `PlayerBarItem.trackItem` stays on the model
    // either way since the overflow menu will need it again.

    private var volumeRow: some View {
        VStack(spacing: 16) {
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
                        // Player.currentVolume is already 0...100 (Compose's own inline volume
                        // slider uses valueRange = 0f..100f directly, no /100 or *100 anywhere)
                        // — not a 0...1 fraction.
                        in: 0...100,
                        onEditingChanged: { editing in
                            guard !editing, let level = volumeDragValue else { return }
                            store.setVolume(id: player.id, level: level)
                            volumeDragValue = nil
                        }
                    )

                    Text("\(Int(volumeDragValue ?? volume))%")
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

/// Flattened queue row — ported directly from `QueueDisplayRows.kt` (a small, pure,
/// dependency-free transform, same "port it directly" precedent as `HomeView.swift`'s
/// `reconciledRows`). Chapters only ever nest under the currently-playing item.
private enum QueueDisplayRow: Identifiable {
    case track(QueueBarItemView, queueIndex: Int)
    case chapter(Chapter, parentId: String)

    var id: String {
        switch self {
        case .track(let item, _): "queue:\(item.id)"
        case .chapter(let chapter, let parentId): "chapter:\(parentId):\(chapter.position)"
        }
    }

    static func build(items: [QueueBarItemView], currentId: String?, chapters: [Chapter]) -> [QueueDisplayRow] {
        var rows: [QueueDisplayRow] = []
        for (index, item) in items.enumerated() {
            rows.append(.track(item, queueIndex: index))
            if item.id == currentId {
                for chapter in chapters {
                    rows.append(.chapter(chapter, parentId: item.id))
                }
            }
        }
        return rows
    }
}

/// Attaches `.itemContextMenu()` only when `enabled` — an unconditional `.itemContextMenu()`
/// would still show an (empty) long-press menu even with zero resolved actions, which Compose
/// avoids for played/unplayable/current rows by using plain `clickable` instead of
/// `combinedClickable` there. Encapsulated as its own `ViewModifier` so the conditional doesn't
/// force the two branches of `queueTrackRow` to unify to the same concrete view type.
private struct QueueRowContextMenu: ViewModifier {
    let item: QueueBarItemView
    let queueId: String?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, let queueId, let trackItem = item.trackItem {
            content.itemContextMenu(
                item: SpikeMediaItem(trackItem),
                context: ItemMenuContext(removeFromQueue: (queueId: queueId, queueItemId: item.id))
            )
        } else {
            content
        }
    }
}
