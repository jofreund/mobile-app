import SwiftUI
import ComposeApp

/// Routes `AppTabView`'s `ItemDetailsRoute` push to the right native screen. Album,
/// Playlist, Podcast, and Audiobook share `ContainerItemDetailsView` below (each has
/// exactly one sub-list, so no tab bar is needed); Artist and Genre get their own screens
/// (`ArtistDetailsView.swift`, `GenreDetailsView.swift`) since their data shape — several
/// independent sections, a two-tab overview — doesn't fit that single-list model. Anything
/// else (there is nothing else left in `MediaType` this app pushes) falls through to
/// `ItemDetailsPlaceholderView`.
struct ItemDetailsView: View {

    let route: ItemDetailsRoute

    var body: some View {
        switch route.mediaType {
        case .artist:
            ArtistDetailsView(route: route)
        case .genre:
            GenreDetailsView(route: route)
        case .album, .playlist, .podcast, .audiobook:
            ContainerItemDetailsView(route: route)
        default:
            ItemDetailsPlaceholderView(route: route)
        }
    }
}

/// The single-sub-list screen for Album/Playlist/Podcast/Audiobook: hero, play/radio
/// buttons, favorite toggle, and the one sub-list each of those types has (tracks,
/// episodes, or chapters).
///
/// Not here yet: sort options, the list/grid view-mode toggle, and disc-number section
/// headers. What *is* here is real: live server data, playback dispatched to whichever
/// player is currently selected (not just this device — see `KmpHelper.playOnSelectedPlayer`),
/// favoriting, and the long-press context menu (`ItemContextMenu.swift`).
struct ContainerItemDetailsView: View {

    let route: ItemDetailsRoute

    @State private var item: AppMediaItem?
    @State private var itemLoadFailed = false
    @State private var isFavorite = false

    @State private var playableItems: [SpikeMediaItem] = []
    @State private var chapters: [Chapter] = []
    @State private var subItemsLoading = false
    @State private var subItemsLoadFailed = false

    var body: some View {
        Group {
            if let item {
                DetailContent(
                    item: item,
                    isFavorite: $isFavorite,
                    playableItems: playableItems,
                    chapters: chapters,
                    subItemsLoading: subItemsLoading,
                    subItemsLoadFailed: subItemsLoadFailed,
                    onPlaylistTrackRemoved: { Task { await load() } }
                )
            } else if itemLoadFailed {
                ContentUnavailableView(
                    String(localized: "item_error"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: route) { await load() }
    }

    @MainActor
    private func load() async {
        item = nil
        itemLoadFailed = false
        playableItems = []
        chapters = []
        subItemsLoadFailed = false
        subItemsLoading = false

        let loaded: AppMediaItem? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchItemDetails(
                itemId: route.itemId,
                mediaType: route.mediaType,
                providerId: route.providerId
            ) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard let loaded else {
            itemLoadFailed = true
            return
        }
        item = loaded
        isFavorite = loaded.favorite?.boolValue ?? false

        switch loaded {
        case let album as Album:
            await loadPlayableItems { KmpHelper.shared.fetchTracksByAlbum(album: album, completion: $0) }
        case let playlist as Playlist:
            await loadPlayableItems { KmpHelper.shared.fetchTracksByPlaylist(playlist: playlist, completion: $0) }
        case let podcast as Podcast:
            await loadPlayableItems { KmpHelper.shared.fetchEpisodesByPodcast(podcast: podcast, completion: $0) }
        case let audiobook as Audiobook:
            chapters = audiobook.chapters ?? []
        default:
            break
        }
    }

    @MainActor
    private func loadPlayableItems(
        _ fetch: @escaping (@escaping ([AppMediaItem]?) -> Void) -> Void
    ) async {
        subItemsLoading = true
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            fetch { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        subItemsLoading = false
        guard let result else {
            subItemsLoadFailed = true
            return
        }
        playableItems = result.map(SpikeMediaItem.init)
    }
}

/// The loaded-item body: hero + the one sub-list this item type has. A separate view
/// (rather than a `@ViewBuilder` method) so the favorite toolbar button can bind
/// directly to the parent's `@State` via `$isFavorite`.
private struct DetailContent: View {

    let item: AppMediaItem
    @Binding var isFavorite: Bool
    let playableItems: [SpikeMediaItem]
    let chapters: [Chapter]
    let subItemsLoading: Bool
    let subItemsLoadFailed: Bool
    let onPlaylistTrackRemoved: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                sectionHeader
                subList
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item.uri != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let next = !isFavorite
                        isFavorite = next
                        _ = KmpHelper.shared.setFavorite(item: item, favorite: next)
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                    }
                }
            }
        }
    }

    private var media: SpikeMediaItem { SpikeMediaItem(item) }

    private var header: some View {
        VStack(spacing: 14) {
            SpikeArtwork(url: media.artworkURL, kind: media.kind, sizing: .fixed(220))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(media.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let subtitle = media.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(String(localized: "action_play_now"), systemImage: "play.fill") {
                    _ = KmpHelper.shared.playOnSelectedPlayer(item: item, option: .replace, radio: false)
                }
                .buttonStyle(.glassProminent)

                if item.canStartRadio {
                    Button(String(localized: "action_start_radio"), systemImage: "dot.radiowaves.left.and.right") {
                        _ = KmpHelper.shared.playOnSelectedPlayer(item: item, option: .replace, radio: true)
                    }
                    .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Text(sectionTitle)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var sectionTitle: String {
        switch item {
        case is Album, is Playlist: String(localized: "media_type_tracks")
        case is Podcast: String(localized: "media_type_episodes")
        case is Audiobook: String(localized: "media_type_chapters")
        default: ""
        }
    }

    @ViewBuilder
    private var subList: some View {
        if item is Audiobook {
            if chapters.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                        ChapterRow(item: item, chapter: chapter)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        } else if subItemsLoading {
            ProgressView()
                .controlSize(.large)
                .padding(.top, 24)
        } else if subItemsLoadFailed {
            ContentUnavailableView(
                String(localized: "library_error"),
                systemImage: "wifi.exclamationmark"
            )
            .padding(.top, 24)
        } else if playableItems.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(playableItems.enumerated()), id: \.element.id) { index, media in
                    PlayableRow(
                        media: media,
                        parentItem: item,
                        index: index,
                        onRemovedFromPlaylist: onPlaylistTrackRemoved
                    )
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "library_empty"),
            systemImage: "tray"
        )
        .padding(.top, 24)
    }
}

/// A track or podcast episode row. Tap dispatches "play now" (queue REPLACE) on the
/// selected player — the same default a plain tap resolves to elsewhere in the app
/// (`DefaultClickOption.PLAY_NOW`). Long-press offers Play From Here / Insert Next /
/// Add to Queue / Start Radio / library / playlist / mark-played actions, same as
/// every other native item row (`ItemContextMenu.swift`) — "Play From Here" and
/// "Remove from Playlist" are only offered here, since this is the one row type that
/// has a parent Album/Playlist context.
private struct PlayableRow: View {

    let media: SpikeMediaItem
    let parentItem: AppMediaItem
    let index: Int
    let onRemovedFromPlaylist: () -> Void

    private var duration: Double? { (media.kotlin as? PlayableItem)?.duration?.doubleValue }

    private var menuContext: ItemMenuContext {
        var context = ItemMenuContext()
        if parentItem is Album || parentItem is Playlist {
            context.parentForPlayFromHere = parentItem
        }
        if let playlist = parentItem as? Playlist, playlist.isEditable {
            context.removeFromPlaylist = (playlistId: playlist.itemId, position: index, onSuccess: onRemovedFromPlaylist)
        }
        return context
    }

    var body: some View {
        Button {
            _ = KmpHelper.shared.playOnSelectedPlayer(item: media.kotlin, option: .replace, radio: false)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let subtitle = media.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let duration, duration > 0 {
                    Text(formattedDuration(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .itemContextMenu(item: media, context: menuContext)
    }
}

private struct ChapterRow: View {

    let item: AppMediaItem
    let chapter: Chapter

    var body: some View {
        Button {
            _ = KmpHelper.shared.playChapterOnSelectedPlayer(item: item, chapterPosition: chapter.position)
        } label: {
            HStack(spacing: 12) {
                Text(chapter.name)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if chapter.duration > 0 {
                    Text(formattedDuration(chapter.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
