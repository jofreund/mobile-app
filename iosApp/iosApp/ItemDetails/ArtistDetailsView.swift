import SwiftUI
import MusicAssistantKit

/// The native artist screen: hero + three independently-loaded sections (mirrors
/// `ItemDetailsViewModel.loadArtistAlbumSections`'s three parallel `viewModelScope.launch`
/// calls, one per section, so a slow "Discography" fetch doesn't block "In library" from
/// showing). Not ported: sort options, the list/grid toggle, and the provider-mapping
/// filter chip `loadAlbumsForProvider`/`loadTopTracksForProvider` back — this always shows
/// whichever provider mapping the cross-provider search landed on first. "Similar artists"
/// (the person.2 toolbar button + sheet Compose's `ItemDetailsScreen.kt` has) was removed
/// entirely, not deferred — a product decision, not a technical gap. `KmpHelper.fetchSimilarArtists`
/// was deleted with it since nothing else used it; Compose's own equivalent is untouched.
struct ArtistDetailsView: View {

    let route: ItemDetailsRoute

    @State private var artist: Artist?
    @State private var hasLoaded = false
    @State private var itemLoadFailed = false
    @State private var isFavorite = false

    @State private var libraryAlbums: SectionLoadState = .loading
    @State private var allAlbums: SectionLoadState = .loading
    @State private var topTracks: SectionLoadState = .loading

    var body: some View {
        Group {
            if let artist {
                content(for: artist)
            } else if itemLoadFailed {
                ContentUnavailableView(
                    String(localized: "item_error"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: route) {
            // Returning to this screen re-runs `.task`, and `load()` clears everything back to
            // a spinner before refetching — so a pop back read as a flicker. An artist's albums
            // and top tracks barely change; pull to refresh is the deliberate way to refetch.
            // Only a load that actually produced an artist counts, so a cancelled or failed
            // one still retries on the next appearance.
            guard !hasLoaded else { return }
            await load()
            hasLoaded = artist != nil
        }
    }

    @ViewBuilder
    private func content(for artist: Artist) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                header(for: artist)
                section(
                    title: String(localized: "artist_section_in_library"),
                    state: libraryAlbums
                )
                section(
                    title: String(localized: "artist_section_all"),
                    state: allAlbums
                )
                section(
                    title: String(localized: "artist_section_top"),
                    state: topTracks,
                    isPlayable: true
                )
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .refreshable { await load(keepingContent: true) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let next = !isFavorite
                    isFavorite = next
                    _ = KmpHelper.shared.setFavorite(item: artist, favorite: next)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                }
            }
        }
    }

    private func header(for artist: Artist) -> some View {
        let media = MediaItem(artist)
        return VStack(spacing: 14) {
            ArtworkView(url: media.artworkURL, kind: media.kind, sizing: .fixed(180))
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

            Button(String(localized: "action_play_now"), systemImage: "play.fill") {
                _ = KmpHelper.shared.playOnSelectedPlayer(item: artist, option: .replace, endlessMix: false)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func section(title: String, state: SectionLoadState, isPlayable: Bool = false) -> some View {
        switch state {
        case .loading:
            sectionShell(title: title) {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        case .failed:
            sectionShell(title: title) {
                ContentUnavailableView(
                    String(localized: "library_error"),
                    systemImage: "wifi.exclamationmark"
                )
                .scaleEffect(0.8)
            }
        case .loaded(let items) where items.isEmpty:
            EmptyView()
        case .loaded(let items):
            sectionShell(title: title) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            ArtistSectionTile(item: item, isPlayable: isPlayable)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func sectionShell<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
            content()
        }
    }

    /// [keepingContent] leaves what's on screen in place while refetching, for pull to refresh —
    /// blanking to a spinner under the user's own finger is exactly the flicker being avoided
    /// above. The first load has nothing to keep, so it clears and shows the spinner as before.
    @MainActor
    private func load(keepingContent: Bool = false) async {
        if !keepingContent {
            artist = nil
            itemLoadFailed = false
            libraryAlbums = .loading
            allAlbums = .loading
            topTracks = .loading
        }

        let loaded: AppMediaItem? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchItemDetails(
                itemId: route.itemId,
                mediaType: route.mediaType,
                providerId: route.providerId
            ) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard let artist = loaded as? Artist else {
            itemLoadFailed = true
            return
        }
        self.artist = artist
        isFavorite = artist.favorite?.boolValue ?? false

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await loadLibraryAlbums(artist) }
            group.addTask { await loadAllAlbums(artist) }
            group.addTask { await loadTopTracks(artist) }
        }
    }

    @MainActor
    private func loadLibraryAlbums(_ artist: Artist) async {
        guard artist.isInLibrary else {
            libraryAlbums = .loaded([])
            return
        }
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchAlbumsByArtist(artist: artist) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        libraryAlbums = result.map { .loaded(Array($0.asMediaItems.prefix(10))) } ?? .failed
    }

    @MainActor
    private func loadAllAlbums(_ artist: Artist) async {
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchArtistAllAlbums(artist: artist) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        allAlbums = result.map { .loaded($0.asMediaItems) } ?? .failed
    }

    @MainActor
    private func loadTopTracks(_ artist: Artist) async {
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchArtistTopTracks(artist: artist) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        topTracks = result.map { .loaded($0.asMediaItems) } ?? .failed
    }
}

/// Shared by `ArtistDetailsView`'s three sections and the genre overview's two tabs —
/// `loading`/`failed`/`loaded` map 1:1 onto `DataState.Loading`/`Error`/`Data` on the
/// Compose side.
enum SectionLoadState {
    case loading
    case failed
    case loaded([MediaItem])
}

/// One tile in a horizontal section row. Albums push via the same implicit
/// `NavigationLink(value:)` mechanism `AppTabView` registers `ItemDetailsRoute` for;
/// tracks (`isPlayable`) dispatch "play now" instead, since tracks have no detail screen
/// anywhere in this app.
private struct ArtistSectionTile: View {

    let item: MediaItem
    let isPlayable: Bool

    var body: some View {
        if isPlayable {
            Button { _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, endlessMix: false) } label: {
                tile
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(
                value: ItemDetailsRoute(
                    itemId: item.kotlin.itemId,
                    mediaType: item.kotlin.mediaType,
                    providerId: item.kotlin.provider
                )
            ) { tile }
                .buttonStyle(.plain)
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .fixed(120))
            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, alignment: .leading)
        .contentShape(.rect)
    }
}

