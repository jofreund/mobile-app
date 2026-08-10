import SwiftUI
import MusicAssistantKit
import os

private let playerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.music-assistant.client",
    category: "ExpandedPlayer"
)

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
    /// Navigation has to leave this view: it's presented as a `fullScreenCover`, so it sits
    /// outside every tab's `NavigationStack` and cannot push. `AppTabView` dismisses and pushes.
    let onNavigateToItem: (ItemDetailsRoute) -> Void
    let onCollapse: () -> Void

    /// Fresh per presentation — matches Compose's own "fresh `PagerState` per mount, seeded
    /// from the current selection" behavior (a `.fullScreenCover` is a new view every time).
    @State private var scrollID: String?

    @State private var pagerHaptic = HapticSignal()

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
                        onNavigateToItem: onNavigateToItem,
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
            pagerHaptic.fire(.selection)
        }
        .haptics(pagerHaptic)
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


private struct ExpandedPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    /// Whether this page is the one currently on screen — gates the live position
    /// subscription so only the visible page's ticker runs, not one per connected player.
    let isSelected: Bool
    let onNavigateToItem: (ItemDetailsRoute) -> Void
    let onCollapse: () -> Void

    @State private var livePosition: Double?
    @State private var positionSub: Cancellable?

    @State private var userDragPosition: Double?
    @State private var releasedSeekPosition: Double?


    @State private var showQueue = false
    @State private var showGroupSettings = false
    /// Optimistic local reorder — reset to `nil` (falling back to `player.queueItems`' own
    /// order) whenever the Kotlin-driven order changes, mirroring Compose's
    /// `remember(items) { mutableStateOf(items) }` reset-on-server-echo.
    @State private var displayOrder: [String]?

    @State private var haptic = HapticSignal()

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
            if player.title != nil {
                seekSection
            }
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
        .sheet(isPresented: $showGroupSettings) {
            GroupSettingsView(player: player, store: store)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Header

    /// Three slots with equal flexible sides, not a pair of `Spacer()`s. Spacers split only the
    /// *leftover* space, so they centre the middle item only when both sides are the same width
    /// — and here they never are: one button leads, two trail, and the group-settings one is
    /// conditional, so the player name sat left of centre and shifted sideways as that button
    /// came and went. Equal-width sides centre the name against the screen instead. Compose hit
    /// this too and solved it with its own `CenteredThreeSlotRow`.
    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            playerPicker
                // Keeps a long player name from squeezing itself instead of the empty sides.
                .layoutPriority(1)

            headerActions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var playerPicker: some View {
        Menu {
            PlayerPickerMenu(store: store, currentId: player.id)
        } label: {
            HStack(spacing: 4) {
                Text(player.name)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 16) {
            // Only shown when there's anything to manage — a bound group or at least one
            // groupable candidate (mirrors when Compose's dialog had content to offer).
            if player.isGrouped || !player.groupMembers.isEmpty {
                Button {
                    showGroupSettings = true
                } label: {
                    Image(systemName: "hifispeaker.2")
                        .font(.title3)
                }
                .accessibilityLabel(String(localized: "players_group_settings"))
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showQueue.toggle() }
            } label: {
                Image(systemName: showQueue ? "list.bullet.circle.fill" : "list.bullet.circle")
                    .font(.title3)
            }
            .accessibilityLabel(String(localized: "cd_toggle_queue"))
        }
    }

    // MARK: - Hero subtitle

    /// "Artist • Album", with each part tappable when there's somewhere to go.
    ///
    /// Built from `trackItem` — the real `Track`, carrying `artists` and `album` as media items —
    /// rather than from `player.subtitle`, which Kotlin has already joined into one string.
    /// Splitting that string back apart would break on any artist or album containing the
    /// separator, and would still leave nothing to navigate *to*.
    ///
    /// Falls back to the plain joined subtitle whenever the structured form isn't available: a
    /// radio stream has no track, and a track can have neither album nor artists.
    @ViewBuilder
    private var heroSubtitle: some View {
        let track = player.trackItem as? Track
        let album = track?.album
        // Compose showed a "choose artist" dialog for multi-artist tracks. One tap target that
        // sometimes needs a second decision is worse here than linking the primary artist, which
        // is the one the joined subtitle named anyway.
        let artist = track?.artists.first

        if album != nil || artist != nil {
            HStack(spacing: 0) {
                if let artist {
                    linkedName(artist.displayName, for: artist)
                }
                if album != nil && artist != nil {
                    Text(" • ").font(.subheadline).foregroundStyle(.secondary)
                }
                if let album {
                    linkedName(album.displayName, for: album)
                }
            }
            .lineLimit(1)
        } else if let subtitle = player.subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func linkedName(_ name: String, for item: AppMediaItem) -> some View {
        Button {
            onNavigateToItem(
                ItemDetailsRoute(
                    itemId: item.itemId,
                    mediaType: item.mediaType,
                    providerId: item.provider
                )
            )
        } label: {
            Text(name)
                .font(.subheadline)
                // `.tint`, not `.secondary`: these are the only tappable words on the screen and
                // nothing else marks them as such — no underline, no chevron, no disclosure.
                .foregroundStyle(.tint)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 16) {
            ArtworkView(url: player.artworkURL, kind: .track, sizing: .flexible(decodeHint: 340))
                .frame(maxWidth: 340)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 12)

            VStack(spacing: 4) {
                Text(player.title ?? player.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                heroSubtitle
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
            ArtworkView(url: player.artworkURL, kind: .track, sizing: .fixed(48))
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

    private var queueLabel: String {
        guard let index = currentQueueIndex else { return String(localized: "queue_label") }
        return String(format: String(localized: "queue_label_with_position"), index + 1, orderedQueueItems.count)
    }

    @ViewBuilder
    private var queueSection: some View {
        // The current item's own row is skipped (its chapters, if any, aren't) — the peek row
        // right above already shows exactly this item, so repeating it as the queue's first row
        // too just duplicates it; matches the Apple Music reference, whose queue lists only what
        // comes *next*, not what's already playing.
        let rows = QueueDisplayRow.build(items: orderedQueueItems, currentId: player.currentQueueItemId, chapters: player.currentItemChapters)
        if rows.isEmpty {
            emptyQueueState
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(queueLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

        // A Button, not .onTapGesture + .contentShape — matches every other tappable row in
        // this codebase (LibraryItemCell, HomeCarouselTile, ...), and .onTapGesture on List row
        // content is a known source of conflicts with List's own edit-mode drag-handle
        // recognizer (found the hard way: reorder didn't work at all with .onTapGesture here).
        return Button {
            guard !isCurrent, item.isPlayable, let queueId = player.queueId else { return }
            store.playQueueItem(queueId: queueId, queueItemId: item.id)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: item.artworkURL, kind: .track, sizing: .fixed(40))
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
        }
        .buttonStyle(.plain)
        .moveDisabled(!canInteract)
        .modifier(QueueRowContextMenu(item: item, queueId: player.queueId, enabled: canInteract))
        .listRowBackground(Color.clear)
        .listRowInsets(Self.queueRowInsets)
        // Keep the separator starting at the title rather than under the artwork. Zeroing the
        // leading inset would otherwise drag it left with the content, since SwiftUI aligns it to
        // wherever the row's content begins.
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.queueTextInset }
    }

    private func queueChapterRow(_ chapter: Chapter) -> some View {
        Button {
            store.seek(id: player.id, seconds: chapter.start.rounded(.up))
        } label: {
            queueChapterRowLabel(chapter)
        }
        .buttonStyle(.plain)
        .moveDisabled(true)
        .listRowBackground(Color.clear)
        .listRowInsets(Self.queueRowInsets)
    }

    /// Zero horizontally, so a queue row starts exactly where the peek row above it does — both
    /// then sit on the player's own 24pt margin, which is what makes the artwork line up. The
    /// list's default inset used to add ~16pt on top of that and pushed the queue visibly right.
    ///
    /// Vertical is spelled out because `listRowInsets` is all-or-nothing: taking the horizontal
    /// values means naming the vertical ones too, so this is a deliberate row height rather than
    /// the inherited default it replaces.
    private static let queueRowInsets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    /// Where a queue row's text starts: 40pt of artwork plus the 12pt `HStack` spacing. Chapter
    /// rows pad by the same amount to hang under the titles, and the separator is aligned to it.
    private static let queueTextInset: CGFloat = 52

    private func queueChapterRowLabel(_ chapter: Chapter) -> some View {
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
        .padding(.leading, Self.queueTextInset)
        .contentShape(Rectangle())
    }

    /// Resolves the flattened display move into a queue-index move, mirroring
    /// `queueIndexAt`/the `toQueueIndex <= currentIdx` reject-guard from `CollapsibleQueue.kt`,
    /// then applies it optimistically to `displayOrder` before dispatching.
    private func handleMove(rows: [QueueDisplayRow], from: IndexSet, to: Int) {
        guard let fromDisplayIndex = from.first, from.count == 1 else { return }
        guard case let .track(fromItem, _) = rows[fromDisplayIndex] else { return }
        guard let queueId = player.queueId else { return }

        // The arithmetic lives in `QueueMoveMath` so it can be tested without a view. Three
        // separate bugs shipped in it — a display-index-vs-queue-index mixup, a pre- vs
        // post-removal `pos_shift` convention error, and a guard that discarded every reorder
        // in an idle queue — and none of them needed a UI to reproduce.
        guard let move = QueueMoveMath.resolve(
            rowQueueIndices: rows.map(\.queueIndex),
            from: fromDisplayIndex,
            to: to,
            currentQueueIndex: currentQueueIndex
        ) else { return }

        var order = displayOrder ?? orderedQueueItems.map(\.id)
        order.move(fromOffsets: IndexSet(integer: move.fromQueueIndex), toOffset: move.localToIndex)
        displayOrder = order

        store.moveQueueItem(
            queueId: queueId,
            queueItemId: fromItem.id,
            from: move.fromQueueIndex,
            to: move.serverToIndex
        )
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
        ContentUnavailableView {
            Label(String(localized: "queue_empty"), systemImage: "music.note.list")
        } actions: {
            Button(browseLibraryLabel) {
                onCollapse()
                KmpHelper.shared.requestHome()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// `queue_browse_library` is stored in the shared string catalog as literal all-caps
    /// ("BROWSE LIBRARY"/"BIBLIOTHEK DURCHSUCHEN", matching Compose's own Material button there)
    /// — nothing else in the native app renders any text in all caps, so this re-cases it
    /// locally (first letter as-is, everything else lowercased) rather than touching the shared
    /// string Compose still uses as-is.
    private var browseLibraryLabel: String {
        let raw = String(localized: "queue_browse_library")
        guard let first = raw.first else { return raw }
        return String(first) + raw.dropFirst().lowercased()
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
            // A dead position flow just looks like a stuck playhead, with nothing else to go on.
            onError: { error in
                playerLog.error("position flow failed: \(String(describing: error), privacy: .public)")
            }
        )
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 28) {
            Button {
                store.toggleShuffle(id: player.id)
                haptic.fire(.selection)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffleEnabled ? .primary : .secondary)
            }
            .disabled(player.isDynamicPlaylist)

            Button {
                store.skipPrevious(id: player.id)
                haptic.fire(.impact(weight: .light))
            } label: {
                Image(systemName: "backward.fill").font(.title2)
            }

            Button {
                store.togglePlayPause(id: player.id)
                haptic.fire(.impact(weight: .medium))
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)

            Button {
                store.skipNext(id: player.id)
                haptic.fire(.impact(weight: .light))
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }

            Button {
                store.cycleRepeatMode(id: player.id)
                haptic.fire(.selection)
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
        .haptics(haptic)
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
                VolumeSlider(
                    volume: volume,
                    isMuted: player.isMuted,
                    canMute: player.canMute,
                    enabled: true,
                    onMuteToggle: { store.toggleMute(id: player.id) },
                    onVolumeSet: { store.setVolume(id: player.id, level: $0) }
                )
            }
        }
    }
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

    /// The absolute queue position, or nil for a chapter row. This is the only thing
    /// `QueueMoveMath` needs from a row, which is what lets the arithmetic be tested without
    /// constructing bridged Kotlin values.
    var queueIndex: Int? {
        switch self {
        case .track(_, let queueIndex): queueIndex
        case .chapter: nil
        }
    }

    /// The current item's own track row is deliberately omitted (its chapters aren't) — see
    /// `queueSection`'s doc comment for why.
    static func build(items: [QueueBarItemView], currentId: String?, chapters: [Chapter]) -> [QueueDisplayRow] {
        var rows: [QueueDisplayRow] = []
        for (index, item) in items.enumerated() {
            if item.id == currentId {
                for chapter in chapters {
                    rows.append(.chapter(chapter, parentId: item.id))
                }
            } else {
                rows.append(.track(item, queueIndex: index))
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
                item: MediaItem(trackItem),
                context: ItemMenuContext(removeFromQueue: (queueId: queueId, queueItemId: item.id))
            )
        } else {
            content
        }
    }
}
