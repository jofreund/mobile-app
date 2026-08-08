import SwiftUI
import ComposeApp

/// The Search tab's root — Phase E3. Reimplements `SearchScreen.kt`/`SearchViewModel.kt`
/// natively rather than wrapping the Kotlin ViewModel, the same approach E2 established for
/// `LibraryListView`: explicit-trigger search (fires on submit or a filter Apply, not per
/// keystroke — `SearchViewModel.onQueryChanged` only updates state, it doesn't itself trigger a
/// search), a media-type filter sheet, and a flat list when exactly one type has results or a
/// sectioned list when more than one does, matching `SearchContent`'s own branch. GENRE is
/// excluded throughout, same as `SearchState.mediaTypes`' commented-out entry — the server
/// doesn't return genres from this endpoint.
struct SearchView: View {

    /// Whether the search field's keyboard is up — threaded up to `AppTabView` so the floating
    /// mini player can hide itself while it is (it otherwise renders squeezed directly above
    /// the keyboard, which looks broken). Driven by `.searchFocused`, not `.searchable`'s own
    /// `isPresented` — `isPresented` stays true for as long as the search UI/scope is active,
    /// including while browsing results with the keyboard already dismissed; `.searchFocused`
    /// tracks literal text-input focus, so it goes false the moment the keyboard is dismissed
    /// (tapping a result, scrolling, swiping down), independent of whether results are shown.
    @Binding var isSearchFieldActive: Bool

    @State private var query = ""
    @State private var selectedTypes: Set<MediaType> = []
    @State private var libraryOnly = false
    @State private var showFilterSheet = false

    @State private var results: SearchResultData?
    @State private var isSearching = false
    @State private var searchFailed = false

    @FocusState private var isSearchFieldFocused: Bool

    private let selectableTypes: [MediaType] = [.track, .artist, .album, .playlist, .podcast, .audiobook, .radio]

    var body: some View {
        content
            .navigationTitle(String(localized: "nav_search"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "library_quick_search")
            )
            .searchFocused($isSearchFieldFocused)
            .onChange(of: isSearchFieldFocused) { _, focused in
                isSearchFieldActive = focused
            }
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .onChange(of: query) {
                if query.isEmpty {
                    results = nil
                    searchFailed = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { filterButton }
            }
            .sheet(isPresented: $showFilterSheet) {
                SearchFilterSheet(
                    selectableTypes: selectableTypes,
                    selectedTypes: selectedTypes,
                    libraryOnly: libraryOnly
                ) { types, onlyLibrary in
                    selectedTypes = types
                    libraryOnly = onlyLibrary
                    if !query.isEmpty {
                        Task { await performSearch() }
                    }
                }
            }
    }

    private var filterButton: some View {
        Button {
            showFilterSheet = true
        } label: {
            Image(
                systemName: !selectedTypes.isEmpty || libraryOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel(String(localized: "cd_filter"))
    }

    @ViewBuilder
    private var content: some View {
        if let results {
            let sections = nonEmptySections(results)
            if sections.isEmpty {
                ContentUnavailableView(String(localized: "search_no_results"), systemImage: "magnifyingglass")
            } else if sections.count == 1 {
                List(sections[0].items) { item in
                    SearchResultRow(item: item)
                }
                .listStyle(.plain)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                SearchResultRow(item: item)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else if searchFailed {
            ContentUnavailableView(String(localized: "search_error"), systemImage: "wifi.exclamationmark")
        } else if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(String(localized: "search_start"), systemImage: "magnifyingglass")
        }
    }

    private struct SearchSection: Identifiable {
        let id: String
        let title: String
        let items: [SpikeMediaItem]
    }

    /// Fixed order — mirrors `SearchViewModel.SearchResults.nonEmptyLists`: Tracks, Artists,
    /// Albums, Playlists, Podcasts, Audiobooks, Radio.
    private func nonEmptySections(_ result: SearchResultData) -> [SearchSection] {
        [
            SearchSection(id: "tracks", title: String(localized: "media_type_tracks"), items: result.tracks.map(SpikeMediaItem.init)),
            SearchSection(id: "artists", title: String(localized: "media_type_artists"), items: result.artists.map(SpikeMediaItem.init)),
            SearchSection(id: "albums", title: String(localized: "media_type_albums"), items: result.albums.map(SpikeMediaItem.init)),
            SearchSection(
                id: "playlists",
                title: String(localized: "media_type_playlists"),
                items: result.playlists.map(SpikeMediaItem.init)
            ),
            SearchSection(
                id: "podcasts",
                title: String(localized: "media_type_podcasts"),
                items: result.podcasts.map(SpikeMediaItem.init)
            ),
            SearchSection(
                id: "audiobooks",
                title: String(localized: "media_type_audiobooks"),
                items: result.audiobooks.map(SpikeMediaItem.init)
            ),
            SearchSection(id: "radios", title: String(localized: "media_type_radio"), items: result.radios.map(SpikeMediaItem.init)),
        ].filter { !$0.items.isEmpty }
    }

    @MainActor
    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = nil
            searchFailed = false
            return
        }
        isSearching = true
        searchFailed = false
        let result: SearchResultData? = await withCheckedContinuation { continuation in
            KmpHelper.shared.searchDetailed(
                query: trimmed,
                mediaTypes: Array(selectedTypes),
                libraryOnly: libraryOnly
            ) { continuation.resume(returning: $0) }
        }
        isSearching = false
        guard let result else {
            searchFailed = true
            return
        }
        results = result
    }
}

/// A search result row — same 48pt-thumbnail list-row shape `LibraryItemCell`'s `listRow`
/// uses, and the same browsable-vs-playable tap dispatch: browsable kinds push
/// `ItemDetailsRoute` onto this tab's own `NavigationStack`, everything else plays now.
private struct SearchResultRow: View {

    let item: SpikeMediaItem

    var body: some View {
        Group {
            if item.kind.isBrowsable {
                NavigationLink(
                    value: ItemDetailsRoute(
                        itemId: item.kotlin.itemId,
                        mediaType: item.kotlin.mediaType,
                        providerId: item.kotlin.provider
                    )
                ) { row }
            } else {
                Button {
                    _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, radio: false)
                } label: {
                    row
                }
                .buttonStyle(.plain)
            }
        }
        .itemContextMenu(item: item)
    }

    private var row: some View {
        HStack(spacing: 12) {
            SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .fixed(48))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// Working-copy-plus-explicit-Apply, same shape as `LibraryFilterSheet` — but simpler: just the
/// media-type multi-select and the library-only toggle, no provider/genre pickers.
private struct SearchFilterSheet: View {

    let selectableTypes: [MediaType]
    let onApply: (Set<MediaType>, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingTypes: Set<MediaType>
    @State private var workingLibraryOnly: Bool

    init(selectableTypes: [MediaType], selectedTypes: Set<MediaType>, libraryOnly: Bool, onApply: @escaping (Set<MediaType>, Bool) -> Void) {
        self.selectableTypes = selectableTypes
        self.onApply = onApply
        _workingTypes = State(initialValue: selectedTypes)
        _workingLibraryOnly = State(initialValue: libraryOnly)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(String(localized: "search_in_library_only"), isOn: $workingLibraryOnly)
                }
                Section(String(localized: "genre_filter_media_type")) {
                    ForEach(selectableTypes, id: \.self) { type in
                        Button {
                            if workingTypes.contains(type) {
                                workingTypes.remove(type)
                            } else {
                                workingTypes.insert(type)
                            }
                        } label: {
                            HStack {
                                Text(type.searchFilterLabel).foregroundStyle(.primary)
                                Spacer()
                                if workingTypes.contains(type) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "filter_sheet_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common_apply")) {
                        onApply(workingTypes, workingLibraryOnly)
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension MediaType {
    var searchFilterLabel: String {
        switch self {
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
}
