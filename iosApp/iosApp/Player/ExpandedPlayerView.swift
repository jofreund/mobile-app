import SwiftUI
import MusicAssistantKit
import os

private let playerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.jofreund.taktgeber",
    category: "ExpandedPlayer"
)

/// Native expanded (full-screen) player — hero, seek, full transport, volume, a player picker,
/// and swipe-down-to-dismiss. Reuses the exact `PlayerBarStore` `AppTabView` already owns and
/// passes to `MiniPlayerView`.
///
/// **There is no swipe between players.** It used to be a paging `ScrollView` spanning the whole
/// screen, which meant a horizontal pan anywhere — including on the seek and volume bars — was a
/// candidate for changing player, and the pager kept winning those. Sliders that cannot be
/// dragged are a worse trade than a swipe that saves a tap, so switching player is now the picker
/// under the controls, within thumb reach. Compose's `ExpandedPlayerPage` did use a
/// `HorizontalPager`; this deliberately diverges.
///
/// The queue list (tap-to-play, drag-to-reorder via native `List.onMove`, long-press via the
/// shared `ItemContextMenu.swift` plus a queue-specific "Delete", chapter rows nested under the
/// current audiobook item, auto-scroll-to-current) is also here — toggled from the icon row,
/// styled after Apple Music: the hero shrinks to a small peek row and the queue fills the space
/// between it and the seek/transport/volume controls, which stay pinned and usable throughout
/// rather than being replaced the way Compose's `CollapsibleQueue` replaces the whole hero.
///
/// Secondary actions — favorite, sleep timer, queue toggle — live in `iconRow`, a bottom row
/// between the volume slider and the player picker, in thumb reach. (Favoriting was once
/// predicted to land in an overflow menu instead; the icon row superseded that.)
///
/// The header's ⋯ menu carries what acts on the queue as a whole: Autoplay, Crossfade (only on
/// servers that report it) and "Transfer queue", which opens `TransferQueueSheet`.
///
/// Deliberately **not** here yet (unreachable until a later phase builds each natively): group
/// management, DSP settings, playback speed, lyrics, and the rest of the overflow menu (power,
/// clear queue, go-to-artist/album). None of the underlying Kotlin/server logic is touched —
/// only their Swift entry point is gone.
struct ExpandedPlayerView: View {

    var store: PlayerBarStore
    /// Navigation has to leave this view: it's presented as a `fullScreenCover`, so it sits
    /// outside every tab's `NavigationStack` and cannot push. `AppTabView` dismisses and pushes.
    let onNavigateToItem: (ItemDetailsRoute) -> Void
    let onCollapse: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if let player = currentPlayer {
                ExpandedPlayerRow(
                    player: player,
                    store: store,
                    onNavigateToItem: onNavigateToItem,
                    onCollapse: onCollapse
                )
            }
        }
        // Its own, not `AppTabView`'s: this is a `fullScreenCover`, so a dialog anchored outside
        // it would never appear over it. See `itemMenuHost()`.
        .itemMenuHost()
    }

    private var currentPlayer: PlayerBarItemView? {
        guard store.players.indices.contains(store.selectedIndex) else { return nil }
        return store.players[store.selectedIndex]
    }
}


private struct ExpandedPlayerRow: View {

    let player: PlayerBarItemView
    let store: PlayerBarStore
    let onNavigateToItem: (ItemDetailsRoute) -> Void
    let onCollapse: () -> Void

    @State private var livePosition: Double?
    @State private var positionSub: Cancellable?

    /// Chapter-relative while a chapter is presented, absolute otherwise — the coordinate
    /// system the slider itself is drawn in.
    @State private var userDragPosition: Double?
    /// Always absolute, even in chapter mode, so the reconciliation against `displayPosition`
    /// below compares like with like.
    @State private var releasedSeekPosition: Double?
    /// The chapter in force when the drag began. Held for the length of the gesture because a
    /// boundary crossed mid-drag must not re-base the value under the user's finger — that
    /// clamps the thumb to the new chapter's start, which reads as the drag being thrown away.
    @State private var draggingChapter: ChapterBarItem?
    /// Drives the timestamps' emphasis alongside `CapsuleSlider`'s own swell.
    @State private var isScrubbing = false


    @State private var showQueue = false
    @State private var showPlayerPicker = false
    @State private var showSleepTimer = false
    @State private var showTransferTargets = false
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
            seekSection
            transportRow
            volumeRow
            iconRow
            playerPicker
            if !showQueue {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        // Breathing room under the volume row when the queue is open, where the layout drops the
        // trailing Spacer and the row would otherwise sit against the bottom safe area. With the
        // queue closed the Spacer absorbs this and nothing moves.
        .padding(.bottom, 24)
        .onAppear { updatePositionSubscription() }
        // Follows the player, not just the appearance. The pager used to re-subscribe via
        // `isSelected` whenever the visible page changed; with the pager gone that signal went
        // with it, and the subscription stayed bound to whichever player was current when the
        // screen opened — so the playhead sat still for every other one.
        .onChange(of: player.id) { _, _ in updatePositionSubscription() }
        .onDisappear { positionSub?.cancel() }
        .onChange(of: displayPosition) { _, newValue in
            guard let released = releasedSeekPosition else { return }
            if abs(newValue - released) < 0.5 { releasedSeekPosition = nil }
        }
        // A queue-item change under an in-flight drag invalidates everything the gesture was
        // aimed at: the latched chapter belongs to the item that just went away, and the
        // released latch would hold the playhead at a position in the previous book. Drop all
        // three rather than seek the new item to wherever the finger happened to be.
        .onChange(of: player.currentQueueItemId) { _, _ in
            userDragPosition = nil
            draggingChapter = nil
            releasedSeekPosition = nil
        }
        // Backstop for the same value. It is held to stop the playhead snapping back while the
        // seek is in flight, and released above once the server's position agrees — but if the
        // server settles somewhere else entirely, or the seek never lands, nothing above ever
        // clears it and the playhead sits frozen for the rest of the session.
        .task(id: releasedSeekPosition) {
            guard releasedSeekPosition != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            releasedSeekPosition = nil
        }
        .onChange(of: player.queueItems.map(\.id)) { _, _ in displayOrder = nil }
        .sheet(isPresented: $showPlayerPicker) {
            PlayerPickerSheet(player: player, store: store)
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerSheet(player: player, store: store)
        }
        .sheet(isPresented: $showTransferTargets) {
            TransferQueueSheet(player: player, store: store)
        }
    }

    // MARK: - Header

    /// The collapse chevron, and — trailing — the overflow menu holding the queue-wide options.
    /// The player name moved to the picker at the bottom and the queue toggle to `iconRow`,
    /// both within thumb reach; what is left up here is the chrome you reach for deliberately.
    private var header: some View {
        HStack {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }
            Spacer(minLength: 0)
            overflowMenu
        }
    }

    // MARK: - Overflow menu (queue settings + transfer)

    /// Autoplay, Crossfade and "Transfer queue" — everything that acts on the queue as a whole
    /// rather than on what is playing right now.
    ///
    /// The two settings are `Toggle`s, which a `Menu` draws as checkmark rows: the current
    /// value is readable without opening anything further, and one tap flips it. They dispatch
    /// through Kotlin with the value as it stands and let it compute the flip — the same
    /// contract the shuffle and repeat buttons use — so nothing here is optimistic; the row
    /// re-draws when the server echoes the change back through `playerBarState`.
    ///
    /// Transfer sits under a divider as the one entry that opens something rather than
    /// changing a setting. The whole menu needs a queue to act on, so it is disabled without
    /// one.
    ///
    /// **The two toggles show their icon only while switched off.** A menu row has one image
    /// slot and the checkmark owns it — the same constraint `PlayerPickerSheet` documents as
    /// its reason for being a sheet — so an enabled setting reads as a checkmark and a
    /// disabled one as its glyph. The icons are still worth it: they make the three entries
    /// scannable, and the row that loses its glyph is exactly the row whose checkmark is
    /// carrying the meaning.
    private var overflowMenu: some View {
        Menu {
            Toggle(isOn: autoplayBinding) {
                // The queue never runs dry — music keeps coming after the last item.
                Label(String(localized: "queue_autoplay"), systemImage: "infinity")
            }
            // Old servers never report crossfade; the row is left out rather than drawn dead.
            if player.crossfadeSupported {
                Toggle(isOn: crossfadeBinding) {
                    // Two lines running into one: the tail of a track blended into the head
                    // of the next.
                    Label(String(localized: "queue_crossfade"), systemImage: "arrow.triangle.merge")
                }
            }
            Divider()
            Button {
                showTransferTargets = true
            } label: {
                Label(String(localized: "queue_transfer"), systemImage: "arrow.left.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                // A bare glyph has almost no area to hit; the menu is the one control up here
                // that isn't a whole-row target.
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(.rect)
        }
        .disabled(player.queueId == nil)
        .accessibilityLabel(String(localized: "cd_more"))
    }

    /// `set` ignores the incoming value on purpose: Kotlin derives the next state from the
    /// current one, so passing SwiftUI's optimistic guess would be the one thing that could
    /// disagree with the server.
    private var autoplayBinding: Binding<Bool> {
        Binding(
            get: { player.autoplayEnabled },
            set: { _ in store.toggleAutoplay(id: player.id, isEnabledNow: player.autoplayEnabled) }
        )
    }

    private var crossfadeBinding: Binding<Bool> {
        Binding(
            get: { player.crossfadeEnabled },
            set: { _ in store.toggleCrossfade(id: player.id, isEnabledNow: player.crossfadeEnabled) }
        )
    }

    /// Lives under the controls rather than in the header, where a thumb can actually reach it.
    ///
    /// It also replaces the swipe between players. That swipe was a horizontal pan on a paging
    /// `ScrollView` wrapping the whole screen, and it kept claiming drags meant for the sliders —
    /// which is what made them impossible to drag. A list you open deliberately is both easier to
    /// hit one-handed and incapable of stealing a gesture from anything else.
    private var playerPicker: some View {
        Button {
            showPlayerPicker = true
        } label: {
            HStack(spacing: 8) {
                PlayerIcon(player.iconId, size: 17, relativeTo: .subheadline)
                Text(player.name)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            // The whole row is the target, not just the text.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Icon row (favorite / sleep timer / queue)

    /// Secondary actions between the volume slider and the player picker — bare glyphs spread
    /// like the transport row, tinted when their state is on and quiet when it is not (the same
    /// vocabulary as the group toggle in `PlayerPickerSheet`). Stays visible while the queue is
    /// open: the queue button has to remain reachable to close it.
    private var iconRow: some View {
        HStack(spacing: 0) {
            favoriteButton
                .frame(maxWidth: .infinity)
            // Old servers (schema < 35) have no sleep-timer commands; the row just closes up.
            if KmpHelper.shared.isSleepTimerSupported() {
                sleepTimerButton
                    .frame(maxWidth: .infinity)
            }
            queueToggle
                .frame(maxWidth: .infinity)
        }
    }

    private var isFavorite: Bool { player.trackItem?.favorite?.boolValue ?? false }

    private var favoriteButton: some View {
        Button {
            guard let item = player.trackItem else { return }
            haptic.fire(.selection)
            store.toggleFavorite(item: item)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        // Disabled rather than hidden so the row's three slots never shift. Only the absence
        // of a track disables it now: `MainDataSource.toggleFavorite` addresses the item by
        // `referenceUri`, which every item has, so the old uri-less guard no longer applies.
        .disabled(player.trackItem == nil)
        .accessibilityLabel(String(localized: isFavorite ? "action_unfavorite" : "action_favorite"))
        .accessibilityAddTraits(isFavorite ? [.isSelected] : [])
    }

    private var sleepTimerActive: Bool {
        guard let expiresAt = player.sleepTimerExpiresAt else { return false }
        return expiresAt > Date.now.timeIntervalSince1970
    }

    private var sleepTimerButton: some View {
        Button {
            showSleepTimer = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                    .font(.title3)
                if sleepTimerActive, let expiresAt = player.sleepTimerExpiresAt {
                    // Self-updating remaining time, same source as the sheet's countdown.
                    Text(
                        timerInterval: Date.now...Date(timeIntervalSince1970: expiresAt),
                        countsDown: true
                    )
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }
            }
            .foregroundStyle(sleepTimerActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel(String(localized: sleepTimerActive ? "cd_sleep_timer" : "cd_sleep_timer_off"))
        .accessibilityAddTraits(sleepTimerActive ? [.isSelected] : [])
    }

    private var queueToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showQueue.toggle() }
        } label: {
            // Bare glyph, no enclosing circle — Apple Music draws its queue button this way.
            // Colour carries the on state: tinted while the queue is showing, quiet when not.
            Image(systemName: "list.bullet")
                .font(.title3)
                .foregroundStyle(showQueue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel(String(localized: "cd_toggle_queue"))
        .accessibilityAddTraits(showQueue ? [.isSelected] : [])
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
        // In chapter mode the chapter name replaces the artist/album line: the book's author is
        // already the title line's companion elsewhere, and while listening the useful "where am
        // I" is the chapter. A blank chapter name falls through to the usual line rather than
        // blanking it — some metadata ships empty names for every chapter.
        if let chapterName = store.presentationChapter?.name, !chapterName.isEmpty {
            Text(chapterName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            structuredHeroSubtitle
        }
    }

    @ViewBuilder
    private var structuredHeroSubtitle: some View {
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
        } else {
            // An idle player has no artist, album or subtitle to show, but dropping the line
            // shortens the hero and shunts everything below it upward — so switching between a
            // playing player and a silent one made the whole column jump. A space holds the line
            // at its natural height; `.hidden()` would too, but this keeps the same
            // subheadline metrics as the two branches above without repeating them.
            Text(" ")
                .font(.subheadline)
                .lineLimit(1)
                .accessibilityHidden(true)
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
                // The chapter rows' hanging indent (see `queueTextInset`) exists to tuck them
                // under the track rows' titles — with no track row on screen at all (an
                // audiobook as the queue's only item, the common audiobook case) there is
                // nothing to hang under and the indent reads as unexplained dead space, so the
                // chapters start at the margin like everything else.
                let hasTrackRows = rows.contains { $0.queueIndex != nil }
                ScrollViewReader { proxy in
                    List {
                        ForEach(rows) { row in
                            queueRowView(row, hasTrackRows: hasTrackRows)
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
    private func queueRowView(_ row: QueueDisplayRow, hasTrackRows: Bool) -> some View {
        switch row {
        case .track(let item, let queueIndex):
            queueTrackRow(item, queueIndex: queueIndex)
        case .chapter(let chapter, _):
            queueChapterRow(chapter, indented: hasTrackRows)
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

    private func queueChapterRow(_ chapter: Chapter, indented: Bool) -> some View {
        Button {
            store.seek(id: player.id, seconds: chapter.start.rounded(.up))
        } label: {
            queueChapterRowLabel(chapter, indented: indented)
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
    /// rows pad by the same amount to hang under the titles (only while there is a track row to
    /// hang under — see `queueSection`), and the separator is aligned to it.
    private static let queueTextInset: CGFloat = 52

    private func queueChapterRowLabel(_ chapter: Chapter, indented: Bool) -> some View {
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
        .padding(.leading, indented ? Self.queueTextInset : 0)
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

    /// Whether there is anything to seek through. A player sitting idle still gets a bar — see
    /// `seekSection` — it just has no position in it.
    private var hasTrack: Bool { player.title != nil }

    /// The chapter the scrubber is drawn against: the one latched at drag start while a drag
    /// is in flight, otherwise whatever Kotlin currently presents. Nil means absolute time —
    /// no chapters, not an audiobook, or the server preference is off.
    private var activeChapter: ChapterBarItem? {
        draggingChapter ?? store.presentationChapter
    }

    private var sliderValue: Double {
        // Pinned to zero with no track, so a position left over from the player selected a moment
        // ago cannot briefly draw a fill on an idle one.
        guard hasTrack, !player.isPoweredOff else { return 0 }
        if let dragging = userDragPosition { return dragging }
        let absolute = releasedSeekPosition ?? displayPosition
        guard let chapter = activeChapter else { return absolute }
        return min(max(absolute - chapter.startSec, 0), chapter.durationSec)
    }

    /// The span of the scrubber: one chapter in chapter mode, the whole item otherwise.
    private var duration: Double {
        max(activeChapter?.durationSec ?? player.duration ?? 0, 1)
    }

    private var seekSection: some View {
        VStack(spacing: 4) {
            CapsuleSlider(
                value: Binding(get: { sliderValue }, set: { userDragPosition = $0 }),
                range: 0...duration,
                // A minute per VoiceOver step. `Slider`'s default would be a fraction of the
                // range, which on a three-minute track and on a six-hour audiobook are wildly
                // different amounts of listening.
                step: 60,
                valueDescription: { formattedDuration($0) },
                onEditingChanged: { editing in
                    withAnimation(.easeOut(duration: 0.2)) { isScrubbing = editing }
                    guard !editing else {
                        // Latch the chapter for the whole gesture before anything can move it.
                        draggingChapter = store.presentationChapter
                        // The bar has no handle, so this is half of the confirmation that a
                        // touch landed — the swell is the other half.
                        haptic.fire(.selection)
                        return
                    }
                    defer {
                        userDragPosition = nil
                        draggingChapter = nil
                    }
                    guard let seekPosition = userDragPosition else { return }
                    if let chapter = draggingChapter {
                        // Kotlin owns the mapping back to absolute, and hands back the exact
                        // position it asked for so the latch below matches what the server
                        // will report.
                        releasedSeekPosition = store.seekWithinChapter(
                            id: player.id,
                            chapter: chapter,
                            relativeSeconds: seekPosition
                        )
                    } else {
                        releasedSeekPosition = seekPosition
                        store.seek(id: player.id, seconds: seekPosition)
                    }
                }
            )
            .disabled(!player.canPlay || player.isPoweredOff)
            // Inert rather than disabled when there is nothing to seek through. `.disabled` would
            // fade the bar to 40%, and the point of keeping it is that an idle player still shows
            // a visible grey track rather than a gap.
            .allowsHitTesting(hasTrack)
            .accessibilityLabel(String(localized: "cd_playback_position"))
            .accessibilityHidden(!hasTrack)

            HStack {
                Text(formattedDuration(sliderValue))
                Spacer()
                Text(formattedDuration(duration))
            }
            .font(.caption)
            // Brighten with the bar. While scrubbing the left-hand figure is the only readout of
            // where you are actually going to land, so it stops being secondary information.
            .foregroundStyle(isScrubbing ? .primary : .secondary)
            .animation(.easeOut(duration: 0.2), value: isScrubbing)
            // Invisible rather than absent: the space is kept, which is the whole reason this
            // section stays on screen for an idle player. Showing 0:00 / 0:00 would be worse than
            // showing nothing — it reads as a loaded track that has not started.
            .opacity(hasTrack ? 1 : 0)
            .accessibilityHidden(!hasTrack)
        }
    }

    /// Re-pointed whenever the player changes. Only one row exists at a time now, so there is no
    /// longer a set of off-screen pages whose tickers need gating — but there is still exactly one
    /// subscription that has to follow the player currently on screen.
    private func updatePositionSubscription() {
        positionSub?.cancel()
        positionSub = nil
        positionSub = KmpHelper.shared.observePlayerBarPosition(playerId: player.id).subscribe(
            onEach: { value in livePosition = value?.doubleValue },
            // A dead position flow just looks like a stuck playhead, with nothing else to go on.
            onError: { error in
                playerLog.error("position flow failed: \(String(describing: error), privacy: .public)")
            }
        )
    }

    // MARK: - Transport

    /// Shuffle and repeat for music; skip-back and skip-forward for spoken word.
    ///
    /// The two outer slots swap wholesale on `player.isSpokenWord` rather than growing the row:
    /// on an audiobook or a podcast episode, shuffling the queue or repeating the item is
    /// meaningless, while jumping past an ad break or back over a missed sentence is what you
    /// reach for — and five buttons is already the width this row can hold at the default text
    /// size. Play/pause and the track skips stay put across the swap, so the transport doesn't
    /// reshuffle itself under the user's thumb when a book follows an album in the queue.
    private var transportRow: some View {
        HStack(spacing: 28) {
            if player.isSpokenWord {
                skipButton(offset: -Self.skipBackSeconds)
            } else {
                Button {
                    store.toggleShuffle(id: player.id)
                    haptic.fire(.selection)
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(player.shuffleEnabled ? .primary : .secondary)
                }
                .disabled(player.isDynamicPlaylist)
            }

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
                // Constant-width by construction — see `PlayPauseIcon`. A plain Image here
                // resized on every toggle, and this row is centred, so the shuffle, skip and
                // repeat controls all slid sideways by half the difference.
                PlayPauseIcon(isPlaying: player.isPlaying)
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)

            Button {
                store.skipNext(id: player.id)
                haptic.fire(.impact(weight: .light))
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }

            if player.isSpokenWord {
                skipButton(offset: Self.skipForwardSeconds)
            } else {
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
        }
        .buttonStyle(.plain)
        .disabled(!player.canPlay)
        .frame(maxWidth: .infinity)
        .haptics(haptic)
    }

    /// The spoken-word skip amounts. Asymmetric on purpose, and the same pair Apple Books,
    /// Overcast and Pocket Casts default to: forward skips an ad break or a slow passage,
    /// back re-hears a sentence you missed. Both have an SF Symbol (`goforward.30`,
    /// `gobackward.10`), so changing either means checking a glyph exists for the new value.
    private static let skipBackSeconds = 10
    private static let skipForwardSeconds = 30

    /// A relative-seek button: negative `offset` skips back, positive skips forward.
    ///
    /// Never dimmed, unlike the shuffle/repeat buttons it replaces — those are toggles whose
    /// secondary tint means "off", while these are momentary actions with no state to report.
    private func skipButton(offset: Int) -> some View {
        Button {
            store.seekBy(id: player.id, seconds: offset)
            haptic.fire(.impact(weight: .light))
        } label: {
            // `gobackward.10` / `goforward.30` carry the figure in the glyph itself, so the
            // amount is visible without a label under an already-crowded row.
            Image(systemName: offset < 0 ? "gobackward.\(-offset)" : "goforward.\(offset)")
                .font(.title3)
        }
        .accessibilityLabel(
            offset < 0
                ? String(localized: "cd_skip_back_seconds")
                : String(localized: "cd_skip_forward_seconds")
        )
        // Nothing to seek through until a track is loaded — matches the scrubber, which goes
        // inert in the same state rather than sending a seek into an empty queue.
        .disabled(!hasTrack)
    }

    private var repeatSymbolName: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    // MARK: - Volume

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
