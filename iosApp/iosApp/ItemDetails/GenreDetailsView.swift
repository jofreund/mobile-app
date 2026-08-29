import SwiftUI
import MusicAssistantKit

/// The native genre screen: hero + a segmented Albums/Artists toggle over the server's
/// recommendation-folder overview, mirroring `ItemDetailsViewModel.loadGenreOverview`'s
/// single fetch-then-split-by-type. No endless-mix button — `onPlayClick` forces
/// `endlessMixMode = false` for `Genre` on the Compose side too.
struct GenreDetailsView: View {

    let route: ItemDetailsRoute

    @State private var genre: Genre?
    @State private var itemLoadFailed = false
    @State private var isFavorite = false
    @State private var hasLoaded = false
    @State private var overview: SectionLoadState = .loading

    private enum Tab: String, CaseIterable {
        case albums, artists
    }
    @State private var selectedTab: Tab = .albums

    var body: some View {
        Group {
            if let genre {
                content(for: genre)
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
            // See ArtistDetailsView: returning here re-runs `.task`, and a reload that blanks
            // to a spinner reads as a flicker. Refetch on pull, not on every appearance.
            guard !hasLoaded else { return }
            await load()
            hasLoaded = genre != nil
        }
    }

    @ViewBuilder
    private func content(for genre: Genre) -> some View {
        VStack(spacing: 0) {
            header(for: genre)

            Picker("", selection: $selectedTab) {
                Text(String(localized: "all_albums")).tag(Tab.albums)
                Text(String(localized: "all_artists")).tag(Tab.artists)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            tabContent
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if genre.uri != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let next = !isFavorite
                        isFavorite = next
                        _ = KmpHelper.shared.setFavorite(item: genre, favorite: next)
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                    }
                }
            }
        }
    }

    private func header(for genre: Genre) -> some View {
        let media = MediaItem(genre)
        return VStack(spacing: 12) {
            ArtworkView(url: media.artworkURL, kind: media.kind, sizing: .fixed(140))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
            Text(media.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(String(localized: "action_play_now"), systemImage: "play.fill") {
                _ = KmpHelper.shared.playOnSelectedPlayer(item: genre, option: .replace, endlessMix: false)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.top, 12)
    }

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)]

    @ViewBuilder
    private var tabContent: some View {
        let filtered: SectionLoadState = {
            guard case .loaded(let items) = overview else { return overview }
            let kind: MediaItem.Kind = selectedTab == .albums ? .album : .artist
            return .loaded(items.filter { $0.kind == kind })
        }()

        ScrollView {
            switch filtered {
            case .loading:
                ProgressView().padding(.top, 40)
            case .failed:
                ContentUnavailableView(
                    String(localized: "library_error"),
                    systemImage: "wifi.exclamationmark"
                )
                .padding(.top, 40)
            case .loaded(let items) where items.isEmpty:
                ContentUnavailableView(
                    String(localized: "library_empty"),
                    systemImage: "tray"
                )
                .padding(.top, 40)
            case .loaded(let items):
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        NavigationLink(
                            value: ItemDetailsRoute(
                                itemId: item.kotlin.itemId,
                                mediaType: item.kotlin.mediaType,
                                providerId: item.kotlin.provider
                            )
                        ) {
                            GenreGridTile(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .refreshable { await load(keepingContent: true) }
    }

    /// [keepingContent] holds the current screen while refetching, for pull to refresh.
    @MainActor
    private func load(keepingContent: Bool = false) async {
        if !keepingContent {
            genre = nil
            itemLoadFailed = false
            overview = .loading
        }

        let loaded: AppMediaItem? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchItemDetails(
                itemId: route.itemId,
                mediaType: route.mediaType,
                providerId: route.providerId
            ) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard let genre = loaded as? Genre else {
            itemLoadFailed = true
            return
        }
        self.genre = genre
        isFavorite = genre.favorite?.boolValue ?? false

        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchGenreOverview(
                itemId: genre.itemId,
                providerId: genre.provider
            ) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        overview = result.map { .loaded($0.asMediaItems) } ?? .failed
    }
}

private struct GenreGridTile: View {

    let item: MediaItem

    var body: some View {
        VStack(alignment: item.kind.prefersCircularArtwork ? .center : .leading, spacing: 8) {
            ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .flexible(decodeHint: 180))
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
