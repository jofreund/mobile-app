import SwiftUI
import MusicAssistantKit

/// Kids mode: the whole app reduced to a Cover Flow of favorites and one player's transport.
///
/// `AppShellRootView` shows this in place of `AppTabView` while `AppPreferences.kidsModeEnabled`
/// is on, so nothing of the normal app is built underneath it — no Home fetch, no tab bar, no
/// mini player. The cards are the favorites the signed-in account sees. Music Assistant keeps
/// favorites per library, not per user, so the room device signs in with the child's account and
/// this fetches through the same favorite filter the Library tab offers, once per enabled
/// `KidsMediaType` (see `.claude/kids-favorites-mode.md`).
///
/// The player is whichever one is selected — the store's projection, not a private one — with
/// `AppPreferences.kidsModePlayerId` applied on top whenever that player is in the list. An
/// account the server restricts to one player needs no setting at all.
///
/// Owns its own `PlayerBarStore`: while it is up this view *is* the shell (`guidelines.md`: one
/// store per shell) and `AppTabView`'s never exists.
struct KidsFavoritesView: View {

    @State private var store = PlayerBarStore()

    @State private var items: [MediaItem]?
    @State private var loadFailed = false
    @State private var reloadTrigger = UUID()
    @State private var wasReady = false
    @State private var subscriptions = KidsSubscriptions()

    /// The card in the middle. Drives the snap, and decides whether a tap plays or scrolls.
    @State private var centeredID: String?
    @State private var haptic = HapticSignal()

    @State private var gate: ParentGateChallenge?
    @State private var gateAnswer = ""

    /// Compact vertical is a phone on its side: the carousel takes the left, the controls the
    /// right. Everything else stacks, carousel above controls. Neither orientation is forced —
    /// `Info.plist` still lists portrait only for iPhone, and this view simply fits whatever it
    /// is given, which on iPad is either.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let preferences = AppPreferences.shared

    var body: some View {
        layout
            .overlay(alignment: .topLeading) { parentGateButton }
            .haptics(haptic)
            // Start/stop rather than a lifetime subscription: this view goes away when kids mode
            // is switched off, and `PlayerBarStore` has no `deinit` of its own. `start()` is
            // idempotent, so the pair is also right if Settings' cover triggers them.
            .onAppear { store.start() }
            .onDisappear { store.stop() }
            .onChange(of: store.players.map(\.id), initial: true) { _, ids in applyPreferredPlayer(ids) }
            .onChange(of: preferences.kidsModePlayerId) { _, _ in applyPreferredPlayer(store.players.map(\.id)) }
            .task(id: reloadTrigger) { await load() }
            .task {
                observeReadiness()
                observeItemChanges()
            }
            .alert(
                String(localized: "kids_parent_gate_title"),
                isPresented: gatePresented,
                presenting: gate
            ) { challenge in
                TextField(String(localized: "kids_parent_gate_answer"), text: $gateAnswer)
                    .keyboardType(.numberPad)
                Button(String(localized: "kids_parent_gate_confirm")) {
                    if challenge.accepts(gateAnswer) {
                        AppRouter.shared.requestSettings()
                    } else {
                        haptic.fire(.error)
                    }
                }
                Button(String(localized: "common_cancel"), role: .cancel) {}
            } message: { challenge in
                Text(String(format: String(localized: "kids_parent_gate_message"), challenge.left, challenge.right))
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var layout: some View {
        if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                carousel
                controls
                    .frame(width: 320)
                    .padding(.trailing, 24)
            }
        } else {
            VStack(spacing: 0) {
                carousel
                    .padding(.top, Self.portraitTopInset)
                controls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
    }

    /// Pushes the carousel down in portrait, away from the status bar and the lock glyph. The
    /// carousel centres itself in whatever height is left, so the cards move by half of this;
    /// tune the number, not the layout.
    private static let portraitTopInset: CGFloat = 96

    // MARK: - Carousel

    private var carousel: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "kids_empty"), systemImage: "heart")
                    } description: {
                        Text(String(localized: "kids_empty_hint"))
                    }
                } else {
                    coverFlow(items)
                }
            } else if loadFailed {
                ContentUnavailableView {
                    Label(String(localized: "kids_load_failed"), systemImage: "wifi.exclamationmark")
                } actions: {
                    Button(String(localized: "kids_retry")) { reloadTrigger = UUID() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let cardSpacing: CGFloat = 20

    /// A horizontal scroll view snapping card by card, with `coverFlowEffect` turning the
    /// neighbours away. Cards are a little over half the width so the next one on either side is
    /// visibly there to swipe to; the side padding lets the first and last card reach the centre.
    private func coverFlow(_ items: [MediaItem]) -> some View {
        GeometryReader { proxy in
            // A card is its artwork plus two lines of text, so height has a say too.
            let artwork = max(min(proxy.size.width * 0.55, proxy.size.height - 72, 380), 80)
            let sideInset = max((proxy.size.width - artwork) / 2, 0)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                    ForEach(items) { item in
                        KidsCoverCard(item: item, artworkSize: artwork)
                            .coverFlowEffect(step: artwork + Self.cardSpacing)
                            .onTapGesture { tapped(item) }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredID, anchor: .center)
            .safeAreaPadding(.horizontal, sideInset)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// The centred card plays; any other card only scrolls to the centre first, so a child
    /// cannot start something by brushing a neighbour.
    private func tapped(_ item: MediaItem) {
        guard centeredID == item.id else {
            withAnimation(.easeOut(duration: 0.3)) { centeredID = item.id }
            return
        }
        guard KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, endlessMix: false) else {
            return
        }
        haptic.fire(.impact(weight: .medium))
    }

    // MARK: - Controls

    private var selectedPlayer: PlayerBarItemView? {
        store.players.indices.contains(store.selectedIndex) ? store.players[store.selectedIndex] : nil
    }

    @ViewBuilder
    private var controls: some View {
        if let player = selectedPlayer {
            VStack(spacing: 20) {
                nowPlaying(player)
                transport(player)
                VolumeSlider(
                    volume: player.volumeLevel,
                    isMuted: player.isMuted,
                    canMute: player.canMute,
                    enabled: player.volumeLevel != nil,
                    onMuteToggle: { store.toggleMute(id: player.id) },
                    onVolumeSet: { store.setVolume(id: player.id, level: $0) }
                )
            }
        } else {
            Text(String(localized: "kids_no_player"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    private func nowPlaying(_ player: PlayerBarItemView) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: player.artworkURL, kind: .track, sizing: .fixed(48))
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title ?? String(localized: "kids_nothing_playing"))
                    .font(.headline)
                    .lineLimit(1)
                Text(
                    [player.subtitle, player.name]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }
                        .joined(separator: " • ")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Previous, play/pause, next — and nothing else. Shuffle, repeat, seek and the queue are
    /// the parent's business, in the normal app.
    private func transport(_ player: PlayerBarItemView) -> some View {
        HStack(spacing: 44) {
            Button {
                store.skipPrevious(id: player.id)
                haptic.fire(.impact(weight: .light))
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 34))
            }
            .accessibilityLabel(String(localized: "cd_kids_previous"))

            Button {
                store.togglePlayPause(id: player.id)
                haptic.fire(.impact(weight: .medium))
            } label: {
                PlayPauseIcon(isPlaying: player.isPlaying)
                    .font(.system(size: 64))
            }
            .accessibilityLabel(String(localized: "cd_kids_play_pause"))

            Button {
                store.skipNext(id: player.id)
                haptic.fire(.impact(weight: .light))
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 34))
            }
            .accessibilityLabel(String(localized: "cd_kids_next"))
        }
        .buttonStyle(.plain)
        .disabled(!player.canPlay)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Parent gate

    /// A quiet lock in the corner. Two seconds of holding it asks the question; a tap does
    /// nothing, so a child pressing everything finds nothing here.
    private var parentGateButton: some View {
        Image(systemName: "lock.fill")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(14)
            .contentShape(.rect)
            .onLongPressGesture(minimumDuration: 2) {
                haptic.fire(.impact(weight: .medium))
                gateAnswer = ""
                gate = ParentGateChallenge.random()
            }
            .accessibilityLabel(String(localized: "cd_kids_parent_exit"))
            .padding(8)
    }

    private var gatePresented: Binding<Bool> {
        Binding(
            get: { gate != nil },
            set: { presented in if !presented { gate = nil } }
        )
    }

    // MARK: - Player selection

    /// Re-applies the configured room player whenever the list changes shape or the setting
    /// does. Selecting by id goes through Kotlin's resolver, which also persists the choice —
    /// on a device that runs kids mode, that is the selection that should stick.
    private func applyPreferredPlayer(_ ids: [String]) {
        guard let preferred = preferences.kidsModePlayerId,
              ids.contains(preferred),
              store.selectedPlayerID != preferred
        else { return }
        store.selectPlayer(id: preferred)
    }

    // MARK: - Loading

    private func load() async {
        loadFailed = false
        var sections: [[MediaItem]?] = []
        for type in preferences.kidsModeMediaTypes {
            sections.append(await fetchFavorites(of: type))
            guard !Task.isCancelled else { return }
        }
        switch KidsFavoritesCatalog.outcome(sections: sections, isReady: KmpHelper.shared.readyForCommands, id: \.id) {
        case .failed:
            // Whatever is on screen stays; an RPC error has already surfaced as a toast. The
            // flag matters for the empty case, and for the reconnect retry below.
            loadFailed = true
        case .loaded(let merged):
            items = merged
            if centeredID == nil || !merged.contains(where: { $0.id == centeredID }) {
                centeredID = merged.first?.id
            }
        }
    }

    /// One page (`LIBRARY_PAGE_SIZE`, 50) of favorites of one type, through the same call and
    /// filter shape as `LibraryListView`. Nil is a timeout, the nil-vs-empty rule as everywhere.
    private func fetchFavorites(of type: KidsMediaType) async -> [MediaItem]? {
        guard let mediaType = MediaType.companion.fromServer(raw: type.serverValue) else { return [] }
        let base = LibraryFilters.companion.DEFAULT
        let filters = base.doCopy(
            favorite: true,
            albumArtistsOnly: base.albumArtistsOnly,
            albumTypes: base.albumTypes,
            hideEmpty: base.hideEmpty,
            genreMediaType: base.genreMediaType,
            providers: base.providers,
            genres: base.genres
        )
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchLibraryItems(
                mediaType: mediaType,
                search: nil,
                offset: 0,
                sortOption: SortConfig.shared.defaultFor(mediaType: mediaType),
                filters: filters
            ) { continuation.resume(returning: $0) }
        }
        return result?.map(MediaItem.init)
    }

    /// Same retry as `HomeView`: a first load that ran before there was a server to talk to is
    /// repeated on the not-ready → ready edge, seeded so the replay of the current value does
    /// not look like an arrival.
    private func observeReadiness() {
        guard subscriptions.readiness == nil else { return }
        wasReady = KmpHelper.shared.readyForCommands
        subscriptions.readiness = KmpHelper.shared.observeReadiness { isReady in
            let ready = isReady.boolValue
            let justBecameReady = ready && !wasReady
            wasReady = ready
            guard justBecameReady, loadFailed || items == nil else { return }
            reloadTrigger = UUID()
        }
    }

    /// A favorite toggled from another device — the parent's phone — should reach the room
    /// device without anyone touching it. Any library change reloads; `.task(id:)` cancels a
    /// load already running, so a burst collapses to the last one. Three small requests, so
    /// reloading on changes to items this list does not even show is the simpler trade.
    private func observeItemChanges() {
        guard subscriptions.itemChanges == nil else { return }
        subscriptions.itemChanges = KmpHelper.shared.itemChanges.subscribe(
            onEach: { _ in reloadTrigger = UUID() },
            onError: { error in
                NativeLog.shared.warn(
                    tag: "KidsFavoritesView",
                    message: "itemChanges failed: \(error.message ?? "unknown")"
                )
            }
        )
    }
}

/// Keeps the two Kotlin subscriptions for exactly as long as the view's state lives and cancels
/// them in `deinit` — the same box `LibraryChangeObserver` uses, for the same reason: tying them
/// to `onDisappear` would drop them while Settings covers the view.
private final class KidsSubscriptions: @unchecked Sendable {
    var readiness: Cancellable?
    var itemChanges: Cancellable?

    deinit {
        readiness?.cancel()
        itemChanges?.cancel()
    }
}

/// One card: artwork with a title and a line under it. Sized by the carousel, which knows the
/// viewport; the text is clipped to one line each so every card is the same height.
private struct KidsCoverCard: View {

    let item: MediaItem
    let artworkSize: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .fixed(artworkSize), showsBorder: true)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            Text(item.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: artworkSize)
        .contentShape(.rect)
    }
}

private extension View {
    /// Cover Flow: the centred card faces the viewer; its neighbours turn away, shrink and dim
    /// in proportion to their distance from the middle of the viewport. `step` is one card
    /// pitch, so the immediate neighbours sit at exactly ±1 and everything further out is
    /// clamped to the same pose.
    ///
    /// Distance is measured against the scroll view's bounds, not the transition phase:
    /// `scrollTransition` only knows how far a view is from the edges, and a neighbour that is
    /// mostly on screen would sit flat. The sign of the angle is what looked right in the
    /// mockup; if the near edges point outward on a device, flip it here and nowhere else.
    func coverFlowEffect(step: CGFloat) -> some View {
        visualEffect { content, proxy in
            let viewport = proxy.bounds(of: .scrollView(axis: .horizontal))
                ?? CGRect(origin: .zero, size: proxy.size)
            let offset = (proxy.size.width / 2 - viewport.midX) / max(step, 1)
            let clamped = max(-1, min(1, offset))
            return content
                .rotation3DEffect(.degrees(Double(clamped) * -40), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .scaleEffect(1 - abs(clamped) * 0.2)
                .opacity(1 - abs(clamped) * 0.35)
        }
    }
}
