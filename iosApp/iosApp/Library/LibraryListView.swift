import SwiftUI
import ComposeApp

/// Where the Library tab's category grid (`LibraryScreen` in Compose) asks to go —
/// mirrors `ItemDetailsRoute`'s shape and reasoning: a plain `Hashable` carrying just
/// what the destination needs, hand-written since `MediaType` can't derive it itself.
struct LibraryCategoryRoute: Hashable {
    let mediaType: MediaType

    static func == (lhs: LibraryCategoryRoute, rhs: LibraryCategoryRoute) -> Bool {
        lhs.mediaType == rhs.mediaType
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(mediaType.name)
    }
}

/// The native screen for one Library category (Artists, Albums, …) — the first slice
/// of Phase E2. Deliberately narrower than Compose's `LibraryListScreen` (472 LOC
/// `LibraryListViewModel`): this is the plain unfiltered list only. Not ported yet:
/// search, sort, the list/grid view-mode toggle, favorite-only filtering, and
/// optimistic playlist creation. `BROWSE` isn't a `MediaType` and never reaches this
/// screen — it stays on Compose's own `MainNav.Browse` push, a separately-scoped
/// path-based tree rather than a flat list.
struct LibraryListView: View {

    let route: LibraryCategoryRoute

    @State private var items: [SpikeMediaItem]?
    @State private var loadFailed = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)]

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView(
                        String(localized: "library_empty"),
                        systemImage: "tray"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(items) { item in
                                LibraryGridTile(item: item)
                            }
                        }
                        .padding(16)
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
        .navigationTitle(categoryTitle)
        .navigationBarTitleDisplayMode(.large)
        .task(id: route) { await load() }
    }

    private var categoryTitle: String {
        switch route.mediaType {
        case .artist: String(localized: "media_type_artists")
        case .album: String(localized: "media_type_albums")
        case .track: String(localized: "media_type_tracks")
        case .playlist: String(localized: "media_type_playlists")
        case .audiobook: String(localized: "media_type_audiobooks")
        case .podcast: String(localized: "media_type_podcasts")
        case .radio: String(localized: "media_type_radio")
        case .genre: String(localized: "media_type_genres")
        default: ""
        }
    }

    @MainActor
    private func load() async {
        items = nil
        loadFailed = false

        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            switch route.mediaType {
            case .artist:
                KmpHelper.shared.fetchArtists { continuation.resume(returning: $0) }
            case .album:
                KmpHelper.shared.fetchAlbums { continuation.resume(returning: $0) }
            case .track:
                KmpHelper.shared.fetchTracks { continuation.resume(returning: $0) }
            case .playlist:
                KmpHelper.shared.fetchPlaylists { continuation.resume(returning: $0) }
            case .audiobook:
                KmpHelper.shared.fetchAudiobooks { continuation.resume(returning: $0) }
            case .podcast:
                KmpHelper.shared.fetchPodcasts { continuation.resume(returning: $0) }
            case .radio:
                KmpHelper.shared.fetchRadioStations { continuation.resume(returning: $0) }
            case .genre:
                KmpHelper.shared.fetchGenres { continuation.resume(returning: $0) }
            default:
                continuation.resume(returning: [])
            }
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            loadFailed = true
            return
        }
        items = result.asSpikeItems
    }
}

/// A tile in the category grid. Browsable kinds (Artist/Album/Playlist/Podcast/
/// Audiobook/Genre) push `ItemDetailsRoute`; Track and RadioStation have no detail
/// screen anywhere in this app, so they dispatch "play now" instead.
private struct LibraryGridTile: View {

    let item: SpikeMediaItem

    var body: some View {
        if item.kind.isBrowsable {
            NavigationLink(
                value: ItemDetailsRoute(
                    itemId: item.kotlin.itemId,
                    mediaType: item.kotlin.mediaType,
                    providerId: item.kotlin.provider
                )
            ) { tile }
                .buttonStyle(.plain)
        } else {
            Button { _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, radio: false) } label: {
                tile
            }
            .buttonStyle(.plain)
        }
    }

    private var tile: some View {
        VStack(alignment: item.kind.prefersCircularArtwork ? .center : .leading, spacing: 8) {
            SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .flexible(decodeHint: 180))
                .frame(maxWidth: .infinity)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: item.kind.prefersCircularArtwork ? .center : .leading)
        .contentShape(.rect)
    }
}
