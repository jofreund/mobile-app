import SwiftUI
import MusicAssistantKit

/// The Search tab's root — Phase E3. Reimplements `SearchScreen.kt`/`SearchViewModel.kt`
/// natively rather than wrapping the Kotlin ViewModel, the same approach E2 established for
/// `LibraryListView`: explicit-trigger search (fires on submit or a filter Apply, not per
/// keystroke — `SearchViewModel.onQueryChanged` only updates state, it doesn't itself trigger a
/// search), a media-type filter sheet, and a flat list when exactly one type has results or a
/// sectioned list when more than one does, matching `SearchContent`'s own branch. GENRE is
/// excluded throughout, same as `SearchState.mediaTypes`' commented-out entry — the server
/// doesn't return genres from this endpoint.
struct SearchView: View {

    @State private var query = ""

    /// Which result group the chips are narrowing to; nil is "All".
    ///
    /// A section id rather than a `MediaType` because the chips filter what is already on
    /// screen — they never change the query, so they have nothing to say to the server and the
    /// selection only has to name one of the sections `nonEmptySections` produced.
    @State private var selectedSectionId: String?

    /// The one filter that *is* part of the query, so it lives in the search field's own scope
    /// bar rather than among the chips. Apple Music splits these the same way: source beside the
    /// field, type chips beneath it.
    @State private var source: SearchSource = .everywhere

    @State private var results: SearchResultData?
    @State private var isSearching = false
    @State private var searchFailed = false

    @FocusState private var isSearchFieldFocused: Bool

    private enum SearchSource: Hashable {
        case everywhere
        case library
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "nav_search"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                // Not `library_quick_search` ("Schnellsuche"), which says nothing about what
                // this field reaches. That key is still right for `LibraryListView`, where the
                // field filters one already-named category; here the whole point is that the
                // search spans types. Mirrors `selectableTypes` above without listing all seven.
                prompt: String(localized: "search_prompt_types")
            )
            .searchFocused($isSearchFieldFocused)
            // Kept visible for as long as the search UI is, not just while typing: after
            // submitting, the scope is the thing most likely to be wrong, and a control that
            // vanishes on the results screen cannot be corrected without refocusing the field.
            .searchScopes($source, activation: .onSearchPresentation) {
                Text(String(localized: "search_scope_everywhere")).tag(SearchSource.everywhere)
                Text(String(localized: "search_scope_library")).tag(SearchSource.library)
            }
            .onChange(of: source) {
                guard !query.isEmpty else { return }
                Task { await performSearch() }
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
    }

    @ViewBuilder
    private var content: some View {
        if let results {
            let sections = nonEmptySections(results)
            if sections.isEmpty {
                ContentUnavailableView(String(localized: "search_no_results"), systemImage: "magnifyingglass")
            } else {
                VStack(spacing: 0) {
                    // Only worth showing when there is a choice to make: with one group, "All"
                    // and that group's chip do the same thing.
                    if sections.count > 1 {
                        chipBar(sections)
                    }
                    resultList(visibleSections(sections))
                }
            }
        } else if searchFailed {
            ContentUnavailableView(String(localized: "search_error"), systemImage: "wifi.exclamationmark")
        } else if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(String(localized: "search_start"), systemImage: "magnifyingglass")
        }
    }

    /// The chosen group, or all of them — falling back to all when a chip's group has vanished
    /// under a newer search rather than showing an empty screen for a selection that no longer
    /// names anything.
    private func visibleSections(_ sections: [SearchSection]) -> [SearchSection] {
        guard let selectedSectionId,
              let chosen = sections.first(where: { $0.id == selectedSectionId })
        else { return sections }
        return [chosen]
    }

    private func chipBar(_ sections: [SearchSection]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(String(localized: "search_filter_all"), isSelected: selectedSectionId == nil) {
                    selectedSectionId = nil
                }
                ForEach(sections) { section in
                    chip(section.title, isSelected: selectedSectionId == section.id) {
                        selectedSectionId = section.id
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func resultList(_ sections: [SearchSection]) -> some View {
        // One group needs no header — either there is only one kind of result, or a chip is
        // already naming it.
        if sections.count == 1 {
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
    }

    private struct SearchSection: Identifiable {
        let id: String
        let title: String
        let items: [MediaItem]
    }

    /// Fixed order — mirrors `SearchViewModel.SearchResults.nonEmptyLists`: Tracks, Artists,
    /// Albums, Playlists, Podcasts, Audiobooks, Radio.
    private func nonEmptySections(_ result: SearchResultData) -> [SearchSection] {
        [
            SearchSection(id: "tracks", title: String(localized: "media_type_tracks"), items: result.tracks.map(MediaItem.init)),
            SearchSection(id: "artists", title: String(localized: "media_type_artists"), items: result.artists.map(MediaItem.init)),
            SearchSection(id: "albums", title: String(localized: "media_type_albums"), items: result.albums.map(MediaItem.init)),
            SearchSection(
                id: "playlists",
                title: String(localized: "media_type_playlists"),
                items: result.playlists.map(MediaItem.init)
            ),
            SearchSection(
                id: "podcasts",
                title: String(localized: "media_type_podcasts"),
                items: result.podcasts.map(MediaItem.init)
            ),
            SearchSection(
                id: "audiobooks",
                title: String(localized: "media_type_audiobooks"),
                items: result.audiobooks.map(MediaItem.init)
            ),
            SearchSection(id: "radios", title: String(localized: "media_type_radio"), items: result.radios.map(MediaItem.init)),
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
                // Always every type. The chips narrow what is displayed, so narrowing the query
                // too would make each chip a round trip — which on a slow server is exactly the
                // lag the chips exist to avoid.
                mediaTypes: [],
                libraryOnly: source == .library
            ) { continuation.resume(returning: $0) }
        }
        isSearching = false
        guard let result else {
            searchFailed = true
            return
        }
        results = result
        // A chip naming a group from the previous query would silently hide most of this one.
        selectedSectionId = nil
    }
}

/// A search result row — same 48pt-thumbnail list-row shape `LibraryItemCell`'s `listRow`
/// uses, and the same browsable-vs-playable tap dispatch: browsable kinds push
/// `ItemDetailsRoute` onto this tab's own `NavigationStack`, everything else plays now.
private struct SearchResultRow: View {

    let item: MediaItem

    @State private var isPressed = false

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
                .buttonStyle(PressReportingButtonStyle { isPressed = $0 })
            }
        }
        .pressHighlight(isPressed)
        .itemContextMenu(item: item)
    }

    private var row: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .fixed(48))
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
