import SwiftUI
import MusicAssistantKit

/// What surrounds a [MediaItem] row/tile that its long-press menu needs to know about —
/// only ever set by `ItemDetailsView.swift`'s `PlayableRow`, since Library/Home/Search show
/// top-level items with no parent container. Mirrors Compose's `ClickContext`/`onRemoveFromPlaylist`
/// plumbing (`PlayableItemWithMenu.kt`), narrowed to what actually varies here.
struct ItemMenuContext {
    /// Non-nil only for a track/episode row inside an Album or Playlist's own detail screen —
    /// enables "Play From Here", which plays *this* item starting at the row, not the row alone.
    var parentForPlayFromHere: AppMediaItem?

    /// Non-nil only inside an *editable* Playlist's track list — enables "Remove from Playlist".
    /// `position` is the 0-based index as currently displayed; `onSuccess` lets the caller
    /// refresh its list after a successful removal (mirrors `ItemDetailsViewModel::reload`).
    var removeFromPlaylist: (playlistId: String, position: Int, onSuccess: () -> Void)?

    /// Non-nil only for an upcoming, playable, non-current row in the expanded player's queue
    /// list — enables "Delete" (removes the item from the queue). Unlike `removeFromPlaylist`,
    /// dispatched with no confirmation dialog, matching Compose's own immediate-dispatch queue
    /// delete; the queue re-renders reactively off the next `playerBarState` emission.
    var removeFromQueue: (queueId: String, queueItemId: String)?

    init(
        parentForPlayFromHere: AppMediaItem? = nil,
        removeFromPlaylist: (playlistId: String, position: Int, onSuccess: () -> Void)? = nil,
        removeFromQueue: (queueId: String, queueItemId: String)? = nil
    ) {
        self.parentForPlayFromHere = parentForPlayFromHere
        self.removeFromPlaylist = removeFromPlaylist
        self.removeFromQueue = removeFromQueue
    }
}

/// One entry in a long-press context menu — mirrors Kotlin's `ItemAction` (minus `Customize`,
/// which opens a default-tap-action settings screen not ported natively yet).
enum ItemMenuAction: Hashable, Identifiable {
    case playNow, insertNextAndPlay, insertNext, addToQueue
    case playFromHere
    case startEndlessMix
    case addToLibrary, removeFromLibrary
    case favorite, unfavorite
    case addToPlaylist
    case removeFromPlaylist
    case markPlayed, markUnplayed
    case removeFromQueue

    var id: Self { self }

    var title: String {
        switch self {
        case .playNow: String(localized: "action_play_now")
        case .insertNextAndPlay: String(localized: "action_insert_next_and_play")
        case .insertNext: String(localized: "action_insert_next")
        case .addToQueue: String(localized: "action_add_to_queue")
        case .playFromHere: String(localized: "action_play_from_here")
        case .startEndlessMix: String(localized: "action_start_endless_mix")
        case .addToLibrary: String(localized: "action_add_to_library")
        case .removeFromLibrary: String(localized: "action_remove_from_library")
        case .favorite: String(localized: "action_favorite")
        case .unfavorite: String(localized: "action_unfavorite")
        case .addToPlaylist: String(localized: "action_add_to_playlist")
        case .removeFromPlaylist: String(localized: "action_remove_from_playlist")
        case .markPlayed: String(localized: "action_mark_played")
        case .markUnplayed: String(localized: "action_mark_unplayed")
        case .removeFromQueue: String(localized: "common_delete")
        }
    }

    var systemImage: String {
        switch self {
        case .playNow: "play.fill"
        case .insertNextAndPlay: "text.insert"
        case .insertNext: "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: "text.append"
        case .playFromHere: "play.circle"
        case .startEndlessMix: "dot.radiowaves.left.and.right"
        case .addToLibrary: "plus.circle"
        case .removeFromLibrary: "minus.circle"
        case .favorite: "heart"
        case .unfavorite: "heart.slash"
        case .addToPlaylist: "text.badge.plus"
        case .removeFromPlaylist: "trash"
        case .markPlayed: "checkmark.circle"
        case .markUnplayed: "arrow.counterclockwise.circle"
        case .removeFromQueue: "trash"
        }
    }

    var isDestructive: Bool { self == .removeFromLibrary || self == .removeFromPlaylist || self == .removeFromQueue }
}

/// Which actions apply to [item] in [context] — ported 1:1 from
/// `ItemActionResolver.resolveLongClickActions` (same "small pure function, port it directly"
/// precedent `HomeView.swift`'s `reconciledRows` already follows: the *decision* of which
/// buttons to show is deterministic client-side policy over fields already on `AppMediaItem`,
/// not protocol/session state — only the actions themselves dispatch through `KmpHelper`).
/// Unlike Compose, this doesn't distinguish a "playable" vs "browsable" call site — item kind
/// alone (`isPlayable`, `is Genre`, `is PodcastEpisode`, `is Audiobook`) already reproduces
/// the same per-kind gating Compose gets from calling this via two different composables.
func resolveMenuActions(for item: MediaItem, context: ItemMenuContext) -> [ItemMenuAction] {
    let kotlin = item.kotlin
    var actions: [ItemMenuAction] = []

    if kotlin.isPlayable {
        actions += [.playNow, .insertNextAndPlay, .insertNext, .addToQueue]
        if context.parentForPlayFromHere != nil {
            actions.append(.playFromHere)
        }
        if kotlin.canStartEndlessMix {
            actions.append(.startEndlessMix)
        }
    }

    if !(kotlin is Genre) {
        if kotlin.isInLibrary {
            actions.append(.removeFromLibrary)
            actions.append(item.isFavorite ? .unfavorite : .favorite)
        } else {
            actions.append(.addToLibrary)
        }
    }

    if KmpHelper.shared.supportsAddToPlaylist(item: kotlin) {
        actions.append(.addToPlaylist)
    }
    if context.removeFromPlaylist != nil {
        actions.append(.removeFromPlaylist)
    }

    if let episode = kotlin as? PodcastEpisode {
        actions.append((episode.fullyPlayed?.boolValue ?? false) ? .markUnplayed : .markPlayed)
    } else if let audiobook = kotlin as? Audiobook {
        actions.append((audiobook.fullyPlayed?.boolValue ?? false) ? .markUnplayed : .markPlayed)
    }

    if context.removeFromQueue != nil {
        actions.append(.removeFromQueue)
    }

    return actions
}

extension View {
    /// Attaches a native long-press context menu to a `MediaItem` row/tile, wired to the
    /// `KmpHelper` bridge methods for every action `resolveMenuActions` can produce. One shared
    /// implementation for `LibraryItemCell`, `HomeCarouselTile`, `SearchResultRow`, and
    /// `ItemDetailsView`'s `PlayableRow` rather than four copies.
    ///
    /// `artworkPreviewSize`: tile call sites pass their artwork's reference size to replace the
    /// system's lifted snapshot with an artwork-only card. The default snapshot is the whole
    /// cell — artwork *plus* the labels below it — on a transparent background, and once the
    /// menu repositions it, the labels and the see-through padding float over neighbouring
    /// tiles and section headers, which reads as the grid's layout breaking. Apple Music lifts
    /// only the artwork for exactly this reason. Passing the same size the tile decodes at
    /// keeps this a memory-cache hit (`ArtworkLoader`'s key includes `maxPixel`), so the
    /// preview never flashes a placeholder mid-animation. Rows keep the default snapshot —
    /// full-width, over their own slot, nothing to overlap.
    ///
    /// **Requires an `itemMenuHost()` somewhere above it** in the same presenting context: the
    /// three actions that put something on screen are raised through that host rather than
    /// presented per cell. See `ItemMenuPresenter` for why.
    func itemContextMenu(
        item: MediaItem,
        context: ItemMenuContext = ItemMenuContext(),
        artworkPreviewSize: CGFloat? = nil
    ) -> some View {
        modifier(ItemContextMenuModifier(item: item, context: context, artworkPreviewSize: artworkPreviewSize))
    }
}

private struct ItemContextMenuModifier: ViewModifier {
    let item: MediaItem
    let context: ItemMenuContext
    let artworkPreviewSize: CGFloat?

    @Environment(\.itemMenuPresenter) private var presenter

    @ViewBuilder
    func body(content: Content) -> some View {
        if let artworkPreviewSize {
            content.contextMenu {
                menuButtons
            } preview: {
                ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .fixed(artworkPreviewSize))
                    // Inset so the artwork keeps the *tile's* corner radius rather than the
                    // platter's. The platter the system lifts a custom preview onto rounds itself
                    // at roughly twice the ~11%-of-the-edge radius `ArtworkView` clips a 140pt
                    // tile to, and it rounds last: a clip can only cut more away, so nothing
                    // inside the preview can round it less, and `.contentShape(.contextMenuPreview,
                    // …)` reshapes only the lift, not the settled preview (confirmed by DTS on
                    // Apple's forums, thread 784012). Padding is the one lever left — it moves the
                    // platter's wider curve out into the margin, where it clips nothing, and the
                    // corner the eye lands on is the artwork's own. 12pt clears it with room to
                    // spare: the curves stop intersecting at 0.293 × (platter − artwork radius),
                    // about 5pt here.
                    .padding(12)
            }
        } else {
            content.contextMenu {
                menuButtons
            }
        }
    }

    private var menuButtons: some View {
        ForEach(resolveMenuActions(for: item, context: context)) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }

    /// The three actions that need something presented hand off to the screen's one
    /// `itemMenuHost()` rather than presenting for themselves — see `ItemMenuPresenter`. A nil
    /// presenter means a call site forgot the host; the action is dropped, so say so rather than
    /// letting a long press appear to do nothing.
    private func present(_ mutate: (ItemMenuPresenter) -> Void) {
        guard let presenter else {
            NativeLog.shared.warn(
                tag: "ItemContextMenu",
                message: "no itemMenuHost() in this screen's hierarchy — action dropped"
            )
            return
        }
        mutate(presenter)
    }

    private func perform(_ action: ItemMenuAction) {
        let kotlin = item.kotlin
        switch action {
        case .playNow:
            _ = KmpHelper.shared.playOnSelectedPlayer(item: kotlin, option: .replace, endlessMix: false)
        case .insertNextAndPlay:
            _ = KmpHelper.shared.playOnSelectedPlayer(item: kotlin, option: .play, endlessMix: false)
        case .insertNext:
            _ = KmpHelper.shared.playOnSelectedPlayer(item: kotlin, option: .next, endlessMix: false)
        case .addToQueue:
            _ = KmpHelper.shared.playOnSelectedPlayer(item: kotlin, option: .add, endlessMix: false)
        case .playFromHere:
            guard let parent = context.parentForPlayFromHere else { return }
            _ = KmpHelper.shared.playFromHere(parent: parent, startItem: kotlin)
        case .startEndlessMix:
            _ = KmpHelper.shared.playOnSelectedPlayer(item: kotlin, option: .replace, endlessMix: true)
        case .addToLibrary:
            _ = KmpHelper.shared.setInLibrary(item: kotlin, inLibrary: true)
        case .removeFromLibrary:
            present { $0.removeFromLibrary = item }
        case .favorite:
            _ = KmpHelper.shared.setFavorite(item: kotlin, favorite: true)
        case .unfavorite:
            _ = KmpHelper.shared.setFavorite(item: kotlin, favorite: false)
        case .addToPlaylist:
            present { $0.addToPlaylist = item }
        case .removeFromPlaylist:
            guard let target = context.removeFromPlaylist else { return }
            present {
                $0.removeFromPlaylist = ItemMenuPresenter.PlaylistRemoval(
                    item: item,
                    playlistId: target.playlistId,
                    position: target.position,
                    onSuccess: target.onSuccess
                )
            }
        case .markPlayed:
            KmpHelper.shared.setMarkPlayed(item: kotlin, played: true) { _ in }
        case .markUnplayed:
            KmpHelper.shared.setMarkPlayed(item: kotlin, played: false) { _ in }
        case .removeFromQueue:
            guard let target = context.removeFromQueue else { return }
            KmpHelper.shared.removeQueueItem(queueId: target.queueId, queueItemId: target.queueItemId)
        }
    }
}

// MARK: - Presentation host

/// What a long-press menu wants put on screen, held once per screen instead of once per cell.
///
/// The three presenting actions — remove-from-library, remove-from-playlist, add-to-playlist —
/// used to be a `confirmationDialog`, a second `confirmationDialog` and a `sheet` attached by
/// `ItemContextMenuModifier` itself, so **every** cell carried all three. That is not free the
/// way an unused modifier sounds like it should be: `contextMenu`'s and `confirmationDialog`'s
/// content closures are non-escaping, so SwiftUI evaluates them while building the cell's body.
/// Each tile was therefore constructing its whole action list (a `KmpHelper` bridge call and a
/// handful of Kotlin property reads), roughly sixteen `String(localized:)` lookups, and about
/// twenty-five view values — for a menu nobody had opened — and then carrying three presentation
/// modifiers in the view graph on top. On a screen of carousels that multiplies by every visible
/// tile, on every body pass.
///
/// Only the `sheet` was genuinely deferred (its content closure *is* `@escaping`).
///
/// Cells now keep only the `contextMenu` itself, whose eager action list is inherent to the API,
/// and route the rest here. One host per presenting context — see `itemMenuHost()`.
@Observable
@MainActor
final class ItemMenuPresenter {

    var removeFromLibrary: MediaItem?
    var addToPlaylist: MediaItem?
    var removeFromPlaylist: PlaylistRemoval?

    /// Carries the row's position and its caller's refresh closure across from the cell that
    /// raised the menu, since the host presenting the dialog has no idea which list it came from.
    struct PlaylistRemoval {
        let item: MediaItem
        let playlistId: String
        let position: Int
        let onSuccess: () -> Void
    }
}

extension EnvironmentValues {
    /// Optional rather than defaulted: a defaulted presenter would swallow actions silently in a
    /// screen that forgot the host. `ItemContextMenuModifier.present` logs the nil case instead.
    @Entry var itemMenuPresenter: ItemMenuPresenter?
}

extension View {
    /// Mounts the shared confirmation dialogs and the Add-to-Playlist sheet for every
    /// `itemContextMenu` beneath this view.
    ///
    /// Needed **once per presenting context**, not once per screen: a `fullScreenCover` or
    /// `sheet` is its own presentation environment, and a dialog anchored outside it will not
    /// appear over it. Today that means `AppTabView` (covering Home, Library, Search and every
    /// pushed detail screen) and `ExpandedPlayerView` (its queue rows). Nesting is fine — the
    /// inner host shadows the outer one through the environment.
    func itemMenuHost() -> some View {
        modifier(ItemMenuHostModifier())
    }
}

private struct ItemMenuHostModifier: ViewModifier {

    @State private var presenter = ItemMenuPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.itemMenuPresenter, presenter)
            .confirmationDialog(
                String(localized: "dialog_remove_from_library_title"),
                isPresented: presented(\.removeFromLibrary),
                titleVisibility: .visible,
                presenting: presenter.removeFromLibrary
            ) { item in
                Button(String(localized: "action_remove"), role: .destructive) {
                    _ = KmpHelper.shared.setInLibrary(item: item.kotlin, inLibrary: false)
                }
                Button(String(localized: "common_cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "dialog_remove_from_library_message"))
            }
            .confirmationDialog(
                String(localized: "dialog_remove_from_playlist_title"),
                isPresented: presented(\.removeFromPlaylist),
                titleVisibility: .visible,
                presenting: presenter.removeFromPlaylist
            ) { removal in
                Button(String(localized: "action_remove"), role: .destructive) {
                    KmpHelper.shared.removeFromPlaylist(
                        playlistId: removal.playlistId,
                        position: Int32(removal.position)
                    ) { success in
                        if success.boolValue { removal.onSuccess() }
                    }
                }
                Button(String(localized: "common_cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "dialog_remove_from_playlist_message"))
            }
            .sheet(item: binding(\.addToPlaylist)) { item in
                AddToPlaylistSheet(item: item.kotlin)
            }
    }

    /// `presenting:` supplies the value; this only has to say whether anything is pending, and
    /// clear it on dismissal.
    private func presented<T>(_ keyPath: ReferenceWritableKeyPath<ItemMenuPresenter, T?>) -> Binding<Bool> {
        Binding(
            get: { presenter[keyPath: keyPath] != nil },
            set: { isPresented in
                if !isPresented { presenter[keyPath: keyPath] = nil }
            }
        )
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<ItemMenuPresenter, T?>) -> Binding<T?> {
        Binding(
            get: { presenter[keyPath: keyPath] },
            set: { presenter[keyPath: keyPath] = $0 }
        )
    }
}

/// "Add to Playlist" picker — mirrors Compose's `AddToPlaylistDialog`: the user's editable,
/// non-dynamic playlists plus a pinned "New Playlist" row.
private struct AddToPlaylistSheet: View {

    let item: AppMediaItem

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist]?
    @State private var loadFailed = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let playlists {
                    List {
                        Button {
                            newPlaylistName = ""
                            showCreatePlaylist = true
                        } label: {
                            Label(String(localized: "playlist_add_new"), systemImage: "plus")
                        }
                        if playlists.isEmpty {
                            Text(String(localized: "playlist_no_editable"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(playlists, id: \.itemId) { playlist in
                                Button(playlist.displayName) {
                                    addTo(playlist)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                } else if loadFailed {
                    ContentUnavailableView(
                        String(localized: "library_error"),
                        systemImage: "wifi.exclamationmark"
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(String(localized: "playlist_add_to_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_cancel")) { dismiss() }
                }
            }
            .alert(String(localized: "playlist_create_title"), isPresented: $showCreatePlaylist) {
                TextField(String(localized: "playlist_name_label"), text: $newPlaylistName)
                Button(String(localized: "common_cancel"), role: .cancel) { newPlaylistName = "" }
                Button(String(localized: "common_create")) { createAndAdd() }
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        let result: [Playlist]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchEditablePlaylists { continuation.resume(returning: $0) }
        }
        guard let result else {
            loadFailed = true
            return
        }
        playlists = result
    }

    private func addTo(_ playlist: Playlist) {
        guard let uri = item.uri else { return }
        KmpHelper.shared.addToPlaylist(itemUri: uri, playlist: playlist) { _ in }
        dismiss()
    }

    private func createAndAdd() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPlaylistName = ""
        guard !name.isEmpty else { return }
        KmpHelper.shared.createPlaylist(name: name) { created in
            guard let created else { return }
            addTo(created)
        }
    }
}
