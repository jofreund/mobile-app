import SwiftUI
import MusicAssistantKit

/// The Search tab's root — Phase E3. Reimplements `SearchScreen.kt`/`SearchViewModel.kt`
/// natively rather than wrapping the Kotlin ViewModel, the same approach E2 established for
/// `LibraryListView`: explicit-trigger search (fires on submit or a change of filter, not per
/// keystroke — `SearchViewModel.onQueryChanged` only updates state, it doesn't itself trigger a
/// search), a row of media-type chips over the results, and headers only when more than one type
/// is on screen, matching `SearchContent`'s own branch. GENRE is excluded throughout, same as
/// `SearchState.mediaTypes`' commented-out entry — the server doesn't return genres from this
/// endpoint.
struct SearchView: View {

    @State private var query = ""

    /// Which result group the chips are narrowing to; nil is "All".
    ///
    /// A section id rather than a `MediaType` because the chips filter what is already on
    /// screen — they never change the query, so they have nothing to say to the server and the
    /// selection only has to name one of the sections a search produced.
    @State private var selectedSectionId: String?

    /// The one filter that *is* part of the query rather than a view over the results, so it
    /// cannot be a chip: changing it re-runs the search. Parked in the toolbar until it gets a
    /// design of its own.
    @State private var libraryOnly = false

    /// The results, already grouped by type — nil until a search lands.
    ///
    /// Grouped once, when a reply arrives, rather than derived inside `content`: every group
    /// holds a fresh `MediaItem` per row, and each of those reads title, subtitle and artwork
    /// back across the Kotlin bridge in its `init`. `content` re-runs on every keystroke and on
    /// every chip tap, so deriving it there rebuilt up to `SEARCH_RESULT_LIMIT` × 7 items — 1400
    /// of them, several bridge calls each, on the main thread — to answer a tap that only changes
    /// which of them to show. That is enough work to swallow a tap, and it is pure waste: the
    /// items cannot have changed, only the selection has.
    @State private var sections: [SearchSection<MediaItem>]?

    @State private var isSearching = false
    @State private var searchFailed = false

    /// Which search the screen belongs to, so a slow reply cannot land on top of a newer one.
    ///
    /// Nothing cancels an in-flight `searchDetailed`, and two can easily be in the air at once —
    /// toggling library-only starts one while a submitted query is still running. Whichever
    /// replied last used to win, and since a landing reply also clears `selectedSectionId`, a
    /// straggler both restored older results and threw away the chip the user had just tapped.
    @State private var searchGeneration = 0

    @FocusState private var isSearchFieldFocused: Bool


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
            .onChange(of: libraryOnly) {
                guard !query.isEmpty else { return }
                Task { await performSearch() }
            }
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .onChange(of: query) {
                if query.isEmpty {
                    sections = nil
                    searchFailed = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { libraryFilterButton }
            }
    }

    /// A menu rather than a bare toggling icon: one filter behind an unlabelled funnel is a state
    /// you cannot read off the screen, and the filled variant alone does not say *which* filter is
    /// on. Naming it costs a tap and makes it legible.
    private var libraryFilterButton: some View {
        Menu {
            Toggle(String(localized: "search_in_library_only"), isOn: $libraryOnly)
        } label: {
            // Bare glyph, no enclosing circle — matching the library's filter button, and for the
            // same reason: the plain symbol has no filled counterpart, so colour reports whether
            // anything is filtering.
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(libraryOnly ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel(String(localized: "cd_filter"))
        .accessibilityAddTraits(libraryOnly ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        if let sections {
            if sections.isEmpty {
                SearchPlaceholder(closesSearch: false, searchFieldFocused: $isSearchFieldFocused) {
                    ContentUnavailableView(String(localized: "search_no_results"), systemImage: "magnifyingglass")
                }
            } else {
                VStack(spacing: 0) {
                    // Only worth showing when there is a choice to make: with one group, "All"
                    // and that group's chip do the same thing.
                    if sections.count > 1 {
                        chipBar(sections)
                    }
                    resultList(SearchSections.visible(sections, selection: selectedSectionId))
                }
            }
        } else if searchFailed {
            SearchPlaceholder(closesSearch: false, searchFieldFocused: $isSearchFieldFocused) {
                ContentUnavailableView(String(localized: "search_error"), systemImage: "wifi.exclamationmark")
            }
        } else if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Nothing typed yet, so there is nothing to preserve — a tap here leaves search
            // altogether rather than only lowering the keyboard.
            SearchPlaceholder(closesSearch: true, searchFieldFocused: $isSearchFieldFocused) {
                ContentUnavailableView(String(localized: "search_start"), systemImage: "magnifyingglass")
            }
        }
    }

    private func chipBar(_ sections: [SearchSection<MediaItem>]) -> some View {
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
                // The padding is half the chip, and padding draws nothing — so without this the
                // hit region is whatever the background style happens to paint. Stating the
                // shape makes the whole capsule tappable, the same reason `SearchResultRow`
                // states one for its row.
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// One `List`, whichever the chips are showing.
    ///
    /// It used to be two — a flat `List(items)` for a single group and a sectioned one for
    /// several — which meant a chip tap swapped one view type for another in the same position.
    /// SwiftUI cannot diff across that: it tears the whole list down and builds a new one, so a
    /// tap that should have re-labelled a header and dropped some rows instead threw away the
    /// scroll position and every row's identity. Same structure either way now; only the headers
    /// come and go.
    private func resultList(_ sections: [SearchSection<MediaItem>]) -> some View {
        List {
            ForEach(sections) { section in
                // One group needs no header — either there is only one kind of result, or a
                // chip is already naming it.
                if sections.count > 1 {
                    Section(section.title) { rows(section) }
                } else {
                    Section { rows(section) }
                }
            }
        }
        .listStyle(.plain)
    }

    private func rows(_ section: SearchSection<MediaItem>) -> some View {
        ForEach(section.items) { item in
            SearchResultRow(item: item)
        }
    }

    /// Fixed order — mirrors `SearchViewModel.SearchResults.nonEmptyLists`: Tracks, Artists,
    /// Albums, Playlists, Podcasts, Audiobooks, Radio.
    private static func sections(from result: SearchResultData) -> [SearchSection<MediaItem>] {
        SearchSections.nonEmpty([
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
        ])
    }

    @MainActor
    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sections = nil
            searchFailed = false
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchFailed = false
        let result: SearchResultData? = await withCheckedContinuation { continuation in
            KmpHelper.shared.searchDetailed(
                query: trimmed,
                // Always every type. The chips narrow what is displayed, so narrowing the query
                // too would make each chip a round trip — which on a slow server is exactly the
                // lag the chips exist to avoid.
                mediaTypes: [],
                libraryOnly: libraryOnly
            ) { continuation.resume(returning: $0) }
        }
        // A reply the screen has already moved past — a newer search is running, and it owns
        // both the results and the chip selection. Leaving `isSearching` alone here is
        // deliberate: that newer search is still in flight.
        guard generation == searchGeneration else { return }
        isSearching = false
        guard let result else {
            searchFailed = true
            return
        }
        sections = Self.sections(from: result)
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

/// An empty-state panel that gets out of the way when tapped.
///
/// With no results on screen there is nothing to scroll, so `.scrollDismissesKeyboard` has
/// nothing to act on and the keyboard sat over half the screen with only the field's own Cancel
/// to remove it. Tapping the empty middle is what people try first.
///
/// A child view rather than a modifier on the parent because of `dismissSearch`: the environment
/// value is only populated *inside* the searchable container, so reading it on the same view that
/// applies `.searchable` would silently do nothing.
private struct SearchPlaceholder<Content: View>: View {

    /// Whether to leave search entirely, or only lower the keyboard.
    ///
    /// True only for the nothing-typed-yet state. Behind the other placeholders there is a query
    /// and its results, and closing search would throw both away for a tap that was probably
    /// meant to reach past the keyboard.
    let closesSearch: Bool

    /// Taken as a focus binding rather than a closure so that the two dismissals below stay
    /// mutually exclusive — see the tap handler.
    @FocusState.Binding var searchFieldFocused: Bool

    @ViewBuilder let content: () -> Content

    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `ContentUnavailableView` only draws its glyph and text; without this the tappable
            // area would be the label, not the empty space around it, which is where people aim.
            .contentShape(.rect)
            .onTapGesture {
                // Exactly one of these, never both. Collapsing the field lowers the keyboard by
                // itself, so clearing the focus state alongside `dismissSearch` is a second,
                // competing write to the same focus — and the next tap on the search field is
                // spent reconciling it instead of activating, which reads as needing two taps.
                if closesSearch {
                    dismissSearch()
                } else {
                    searchFieldFocused = false
                }
            }
    }
}
