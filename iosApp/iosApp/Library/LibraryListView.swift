import SwiftUI
import MusicAssistantKit

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
/// of Phase E2, now feature-complete against Compose's `LibraryListScreen` (472 LOC
/// `LibraryListViewModel`): search, sort, offset+limit pagination,
/// favorite/provider/genre filters, the list/grid view-mode toggle, and playlist
/// creation are all ported. `BROWSE` isn't a `MediaType` and never reaches this
/// screen — it stays on `BrowseView`, a separately-scoped path-based tree rather
/// than a flat list.
/// Outlives the view, which is the point. SwiftUI rebuilds a `navigationDestination`'s body
/// when the stack pops back to it, so `items` starts nil again and the screen blanks to a
/// spinner until the refetch lands — that quarter-second of empty white is the flicker you see
/// coming back from an artist page. Seeding from here puts the previous result on the first
/// frame, and the refetch then replaces it in place rather than after a gap.
///
/// Bounded, because the key includes the search query: without a cap, every search typed in
/// every category would be retained for the process's lifetime.
@MainActor
private enum LibraryListCache {
    private static var entries: [String: [SpikeMediaItem]] = [:]
    private static var order: [String] = []
    private static let limit = 8

    static func items(for key: String) -> [SpikeMediaItem]? { entries[key] }

    static func store(_ items: [SpikeMediaItem], for key: String) {
        if entries.updateValue(items, forKey: key) == nil { order.append(key) }
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// Kotlin data classes carry a structural `toString`, so interpolating them keys on the
    /// values rather than on object identity.
    static func key(
        route: LibraryCategoryRoute,
        query: String,
        sort: SortOption,
        filters: LibraryFilters
    ) -> String {
        "\(route.mediaType.name)|\(query)|\(sort)|\(filters)"
    }
}

struct LibraryListView: View {

    let route: LibraryCategoryRoute

    @State private var items: [SpikeMediaItem]?
    @State private var loadFailed = false
    @State private var searchQuery = ""
    @State private var sortOption: SortOption
    @State private var filters: LibraryFilters
    @State private var showFilterSheet = false
    @State private var viewMode: ViewMode
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var isCreatingPlaylist = false
    @State private var createPlaylistFailed = false

    private let availableSortFields: [SortField]
    private let pageSize = 50

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)]

    init(route: LibraryCategoryRoute) {
        self.route = route
        self.availableSortFields = SortConfig.shared.fieldsFor(mediaType: route.mediaType)
        let sort = SortConfig.shared.defaultFor(mediaType: route.mediaType)
        let initialFilters = KmpHelper.shared.libraryFilters(mediaType: route.mediaType).value
            ?? LibraryFilters.companion.DEFAULT
        _sortOption = State(initialValue: sort)
        _filters = State(initialValue: initialFilters)
        _viewMode = State(initialValue: KmpHelper.shared.viewMode(mediaType: route.mediaType).value ?? .grid)
        _items = State(
            initialValue: LibraryListCache.items(
                for: LibraryListCache.key(route: route, query: "", sort: sort, filters: initialFilters)
            )
        )
    }

    /// Debounces `searchQuery` edits without hand-rolled Task bookkeeping: `.task(id:)`
    /// cancels and restarts on every keystroke, so only the sleep following the last
    /// keystroke in a burst ever reaches `load()`. Also carries `route`, `sortOption`,
    /// and `filters`, so switching categories, sort, or filters reloads too — all four
    /// funnel through the same debounce delay (imperceptible on a fresh navigation,
    /// sort tap, or filter Apply; correct for a query edit).
    private struct LoadKey: Equatable {
        let route: LibraryCategoryRoute
        let query: String
        let sortOption: SortOption
        let filters: LibraryFilters
    }

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    emptyState
                } else if viewMode == .list {
                    listContent(items)
                } else {
                    gridContent(items)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) { viewModeToggle }
            ToolbarItem(placement: .primaryAction) { filterButton }
            if availableSortFields.count > 1 {
                ToolbarItem(placement: .primaryAction) { sortMenu }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            LibraryFilterSheet(mediaType: route.mediaType, initialFilters: filters) { applied in
                filters = applied
                KmpHelper.shared.setLibraryFilters(mediaType: route.mediaType, filters: applied)
            }
        }
        .alert(String(localized: "playlist_create_title"), isPresented: $showCreatePlaylist) {
            TextField(String(localized: "playlist_name_label"), text: $newPlaylistName)
            Button(String(localized: "common_cancel"), role: .cancel) { newPlaylistName = "" }
            Button(String(localized: "common_create")) { submitCreatePlaylist() }
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(String(localized: "toast_error_create_playlist"), isPresented: $createPlaylistFailed) {
            Button(String(localized: "common_cancel"), role: .cancel) {}
        }
        .task(id: LoadKey(route: route, query: searchQuery, sortOption: sortOption, filters: filters)) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// List mode is a real `List`, which is what makes these rows read as Apple Music's do: the
    /// disclosure indicator on rows that navigate, the press highlight, and separators inset to
    /// the text rather than the artwork all come from `List` + `NavigationLink`. The previous
    /// version was a `LazyVStack` inside a `ScrollView` with hand-drawn `Divider`s, which can
    /// reproduce the lines but none of the behaviour — and got no chevron at all, since there
    /// was no list to draw one.
    ///
    /// Grid mode stays a `ScrollView`; a `List` has nothing to offer a grid of tiles.
    private func listContent(_ items: [SpikeMediaItem]) -> some View {
        List {
            if showsCreatePlaylistRow {
                createPlaylistRow
                    .listRowSeparator(.hidden)
            }
            ForEach(items) { item in
                LibraryItemCell(item: item, viewMode: viewMode)
                    .onAppear { loadMoreIfNeeded(current: item) }
            }
            if isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private func gridContent(_ items: [SpikeMediaItem]) -> some View {
        ScrollView {
            if showsCreatePlaylistRow {
                createPlaylistRow
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(items) { item in
                    LibraryItemCell(item: item, viewMode: viewMode)
                        .onAppear { loadMoreIfNeeded(current: item) }
                }
            }
            .padding(16)
            if isLoadingMore {
                ProgressView().padding(.vertical, 12)
            }
        }
        .refreshable { await load() }
    }

    /// Kept in a `ScrollView` so pull-to-refresh still works with nothing on screen — the one
    /// state where a user is most likely to try it.
    private var emptyState: some View {
        ScrollView {
            if showsCreatePlaylistRow {
                createPlaylistRow
            }
            ContentUnavailableView(
                String(localized: "library_empty"),
                systemImage: "tray"
            )
            .padding(.top, 40)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await load() }
    }

    private var showsCreatePlaylistRow: Bool { route.mediaType == .playlist }

    private var createPlaylistRow: some View {
        Button {
            newPlaylistName = ""
            showCreatePlaylist = true
        } label: {
            Label(String(localized: "playlist_add_new"), systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isCreatingPlaylist)
        .accessibilityLabel(String(localized: "cd_add_playlist"))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var viewModeToggle: some View {
        Button {
            let next: ViewMode = viewMode == .grid ? .list : .grid
            viewMode = next
            KmpHelper.shared.setViewMode(mediaType: route.mediaType, mode: next)
        } label: {
            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
        }
        .accessibilityLabel(String(localized: "cd_toggle_view_mode"))
    }

    private var filterButton: some View {
        Button {
            showFilterSheet = true
        } label: {
            Image(systemName: filters.hasActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(String(localized: "cd_filter"))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSortFields, id: \.self) { field in
                Button {
                    sortOption = field == sortOption.field
                        ? SortOption(field: field, descending: !sortOption.descending)
                        : SortOption(field: field, descending: false)
                } label: {
                    if field == sortOption.field {
                        Label(field.localizedName, systemImage: sortOption.descending ? "arrow.down" : "arrow.up")
                    } else {
                        Text(field.localizedName)
                    }
                }
            }
        } label: {
            Label(sortOption.field.localizedName, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(String(localized: "cd_sort_direction"))
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

    /// Mirrors `AdaptiveMediaGrid`'s `derivedStateOf` over `LazyGridState.layoutInfo`
    /// (10-from-the-end trigger), but SwiftUI's `LazyVGrid` exposes no scroll-offset
    /// API — `.onAppear` on each tile is the idiomatic native equivalent.
    private func loadMoreIfNeeded(current item: SpikeMediaItem) {
        guard let items, hasMore, !isLoadingMore else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard index >= items.count - 10 else { return }
        Task { await loadMore() }
    }

    /// Mirrors `ActionsViewModel.createPlaylist`'s await-the-confirmation contract
    /// (via `KmpHelper.createPlaylist`, wired the same way `LibraryFilterAction`'s
    /// Apply reloads this screen): a `nil` result covers both "request failed" and
    /// "no confirming event within the timeout" — the create may still have
    /// succeeded in the latter case, so a manual refresh recovers either way,
    /// matching the Kotlin helper's own doc comment.
    @MainActor
    private func submitCreatePlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPlaylistName = ""
        guard !name.isEmpty else { return }
        isCreatingPlaylist = true
        Task {
            defer { isCreatingPlaylist = false }
            let created: Playlist? = await withCheckedContinuation { continuation in
                KmpHelper.shared.createPlaylist(name: name) { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            if created != nil {
                await load()
            } else {
                createPlaylistFailed = true
            }
        }
    }

    @MainActor
    private func load() async {
        // Deliberately does *not* clear `items` first. Whatever is on screen stays there until
        // the new result arrives — a sort tap or filter change swaps content in place instead
        // of flashing an empty screen, and a rebuilt view keeps whatever the cache seeded.
        loadFailed = false
        hasMore = true

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchLibraryItems(
                mediaType: route.mediaType,
                search: query.isEmpty ? nil : query,
                offset: 0,
                sortOption: sortOption,
                filters: filters
            ) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            loadFailed = true
            return
        }
        let loaded = result.asSpikeItems
        items = loaded
        hasMore = result.count >= pageSize
        LibraryListCache.store(
            loaded,
            for: LibraryListCache.key(route: route, query: query, sort: sortOption, filters: filters)
        )
    }

    @MainActor
    private func loadMore() async {
        guard let currentItems = items, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchLibraryItems(
                mediaType: route.mediaType,
                search: query.isEmpty ? nil : query,
                offset: Int32(currentItems.count),
                sortOption: sortOption,
                filters: filters
            ) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            hasMore = false
            return
        }
        let existingIds = Set(currentItems.map(\.id))
        items = currentItems + result.asSpikeItems.filter { !existingIds.contains($0.id) }
        hasMore = result.count >= pageSize
    }
}

private extension SortField {
    var localizedName: String {
        switch self {
        case .original: String(localized: "sort_original")
        case .name: String(localized: "sort_name")
        case .duration: String(localized: "sort_duration")
        case .dateAdded: String(localized: "sort_date_added")
        case .dateModified: String(localized: "sort_date_modified")
        case .lastPlayed: String(localized: "sort_last_played")
        case .playCount: String(localized: "sort_play_count")
        case .year: String(localized: "sort_year")
        case .position: String(localized: "sort_position")
        case .artistName: String(localized: "sort_artist")
        case .releaseDate: String(localized: "sort_release_date")
        default: displayName
        }
    }
}

/// A cell in the category list/grid. Browsable kinds (Artist/Album/Playlist/Podcast/
/// Audiobook/Genre) push `ItemDetailsRoute`; Track and RadioStation have no detail
/// screen anywhere in this app, so they dispatch "play now" instead. Mirrors the
/// Compose `*WithMenu` composables' own `viewMode` branch (`BrowsableItemWithMenu.kt`/
/// `PlayableItemWithMenu.kt`): same navigation/play dispatch either way, only the
/// visual layout (`gridTile` vs `listRow`) changes.
private struct LibraryItemCell: View {

    let item: SpikeMediaItem
    let viewMode: ViewMode

    var body: some View {
        Group {
            if item.kind.isBrowsable {
                NavigationLink(
                    value: ItemDetailsRoute(
                        itemId: item.kotlin.itemId,
                        mediaType: item.kotlin.mediaType,
                        providerId: item.kotlin.provider
                    )
                ) { content }
                    .buttonStyle(.plain)
            } else {
                Button { _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, radio: false) } label: {
                    content
                }
                .buttonStyle(.plain)
            }
        }
        .itemContextMenu(item: item)
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .list: listRow
        default: gridTile
        }
    }

    private var gridTile: some View {
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

    /// Sized and spaced after Apple Music's library rows. No horizontal padding of its own any
    /// more — the enclosing `List` supplies row insets, and adding to them pushed the artwork
    /// further in than Apple Music's.
    private var listRow: some View {
        HStack(spacing: Self.artworkGap) {
            SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .fixed(Self.artworkSize))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    // One line, like Apple Music. Wrapping to two made rows in a long list
                    // uneven, which is most of what made this look unlike it.
                    .font(.body)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        // Separators start at the text, not under the artwork — the detail that reads as
        // "native list" versus "rows with lines between them".
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.artworkSize + Self.artworkGap }
    }

    private static let artworkSize: CGFloat = 48
    private static let artworkGap: CGFloat = 12
}
