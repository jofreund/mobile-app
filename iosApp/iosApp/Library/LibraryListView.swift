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
/// `LibraryListViewModel`): a flat, searchable list, no pagination (each category
/// fetches its whole result set — `KmpHelper.fetchLibraryItems` still caps tracks at
/// `TRACKS_FETCH_LIMIT`, same as the unsearched path). Not ported yet: sort, the
/// list/grid view-mode toggle, favorite/provider/genre filters, and optimistic
/// playlist creation. `BROWSE` isn't a `MediaType` and never reaches this screen — it
/// stays on `BrowseView`, a separately-scoped path-based tree rather than a flat list.
struct LibraryListView: View {

    let route: LibraryCategoryRoute

    @State private var items: [SpikeMediaItem]?
    @State private var loadFailed = false
    @State private var searchQuery = ""

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)]

    /// Debounces `searchQuery` edits without hand-rolled Task bookkeeping: `.task(id:)`
    /// cancels and restarts on every keystroke, so only the sleep following the last
    /// keystroke in a burst ever reaches `load()`. Also carries `route`, so switching
    /// categories reloads too — both changes funnel through the same debounce delay
    /// (imperceptible on a fresh navigation, correct for a query edit).
    private struct LoadKey: Equatable {
        let route: LibraryCategoryRoute
        let query: String
    }

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
        // Explicit placement, not .automatic: with a .large navigation title, .automatic
        // has been observed to render the field but never let it become first responder
        // (no keyboard, no cursor) — a known-flaky combination on early iOS 26 betas.
        // .navigationBarDrawer(displayMode: .always) is the classic below-the-title bar,
        // always present rather than collapsing into the nav bar on scroll.
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "library_quick_search")
        )
        .task(id: LoadKey(route: route, query: searchQuery)) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await load()
        }
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

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchLibraryItems(
                mediaType: route.mediaType,
                search: query.isEmpty ? nil : query
            ) { continuation.resume(returning: $0) }
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
