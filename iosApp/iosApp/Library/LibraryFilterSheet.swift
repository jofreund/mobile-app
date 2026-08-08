import SwiftUI
import ComposeApp

/// `LibraryListView`'s filter sheet — mirrors `LibraryFilterAction`/`SettingsSheet`'s
/// working-copy-plus-explicit-Apply contract, but as a real `.sheet` with a
/// `NavigationStack`/`Form` instead of a bottom sheet, since that's the native iOS
/// idiom for this shape of editor. Edits accumulate in local `@State` (not the
/// `LibraryFilters` passed in, which is immutable Kotlin `val`s) and only become a
/// single `LibraryFilters` — via `doCopy`, since Kotlin/Native doesn't bridge data
/// class default arguments — when the user taps Apply.
struct LibraryFilterSheet: View {

    let mediaType: MediaType
    let initialFilters: LibraryFilters
    let onApply: (LibraryFilters) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var favorite: Bool
    @State private var albumArtistsOnly: Bool
    @State private var albumTypes: Set<AlbumType>
    @State private var hideEmpty: GenreEmptyFilter
    @State private var genreMediaType: MediaType?
    @State private var providers: Set<String>
    @State private var genres: Set<Int32>

    @State private var providerOptions: [LibraryProviderOption] = []
    @State private var genreOptions: [LibraryGenreOption] = []

    init(mediaType: MediaType, initialFilters: LibraryFilters, onApply: @escaping (LibraryFilters) -> Void) {
        self.mediaType = mediaType
        self.initialFilters = initialFilters
        self.onApply = onApply
        _favorite = State(initialValue: initialFilters.favorite)
        _albumArtistsOnly = State(initialValue: initialFilters.albumArtistsOnly)
        _albumTypes = State(initialValue: Set(initialFilters.albumTypes))
        _hideEmpty = State(initialValue: initialFilters.hideEmpty)
        _genreMediaType = State(initialValue: initialFilters.genreMediaType)
        _providers = State(initialValue: Set(initialFilters.providers))
        _genres = State(initialValue: Set(initialFilters.genres.map(\.int32Value)))
    }

    /// Providers only when >1 serves this type (a single-provider case like a
    /// podcasts-only setup gains nothing from the filter); genres only when there
    /// are any for this type. Neither on the genres list itself. Matches
    /// `LibraryFilterAction`'s `showProviders`/`showGenres` exactly.
    private var showProviders: Bool { mediaType != .genre && providerOptions.count > 1 }
    private var showGenres: Bool { mediaType != .genre && !genreOptions.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(String(localized: "filter_favorites"), isOn: $favorite)
                }

                if mediaType == .artist {
                    Section {
                        Toggle(String(localized: "filter_album_artists_only"), isOn: $albumArtistsOnly)
                    }
                }

                if mediaType == .album {
                    Section(String(localized: "filter_album_types")) {
                        ForEach(AlbumType.entries, id: \.self) { type in
                            multiSelectRow(String(localized: type.localizationKey), isSelected: albumTypes.contains(type)) {
                                toggle(&albumTypes, type)
                            }
                        }
                    }
                }

                if mediaType == .genre {
                    Section(String(localized: "genre_filter_show")) {
                        Picker(String(localized: "genre_filter_show"), selection: $hideEmpty) {
                            Text(String(localized: "genre_filter_empty_default")).tag(GenreEmptyFilter.default_)
                            Text(String(localized: "genre_filter_empty_non_empty")).tag(GenreEmptyFilter.nonEmpty)
                            Text(String(localized: "genre_filter_empty_all")).tag(GenreEmptyFilter.all)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    Section(String(localized: "genre_filter_media_type")) {
                        Picker(String(localized: "genre_filter_media_type"), selection: $genreMediaType) {
                            Text(String(localized: "genre_filter_media_type_all")).tag(MediaType?.none)
                            ForEach(MediaType.companion.genreMediaTypeOptions, id: \.self) { type in
                                Text(String(localized: type.localizationKey)).tag(MediaType?.some(type))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                if showProviders {
                    Section(String(localized: "filter_providers")) {
                        ForEach(providerOptions, id: \.instanceId) { option in
                            multiSelectRow(option.label, isSelected: providers.contains(option.instanceId)) {
                                toggle(&providers, option.instanceId)
                            }
                        }
                    }
                }

                if showGenres {
                    Section(String(localized: "filter_genres")) {
                        ForEach(genreOptions, id: \.genreId) { option in
                            multiSelectRow(option.label, isSelected: genres.contains(option.genreId)) {
                                toggle(&genres, option.genreId)
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
                    Button(String(localized: "common_apply")) { apply() }
                }
            }
        }
        .task { await loadOptions() }
    }

    private func multiSelectRow(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    /// Idempotent per sheet presentation, mirroring `loadFilterOptions`'s
    /// once-per-VM guard — `.task` itself already runs once per sheet appearance.
    /// Skipped for GENRE, which has no provider/genre filters (mirrors Compose).
    @MainActor
    private func loadOptions() async {
        guard mediaType != .genre else { return }

        async let providerResult: [LibraryProviderOption]? = withCheckedContinuation { continuation in
            KmpHelper.shared.fetchLibraryProviderOptions(mediaType: mediaType) { continuation.resume(returning: $0) }
        }
        async let genreResult: [LibraryGenreOption]? = withCheckedContinuation { continuation in
            KmpHelper.shared.fetchLibraryGenreOptions(mediaType: mediaType) { continuation.resume(returning: $0) }
        }
        let (loadedProviders, loadedGenres) = await (providerResult, genreResult)
        guard !Task.isCancelled else { return }
        providerOptions = loadedProviders ?? []
        genreOptions = loadedGenres ?? []
    }

    private func apply() {
        let result = initialFilters.doCopy(
            favorite: favorite,
            albumArtistsOnly: albumArtistsOnly,
            albumTypes: Array(albumTypes),
            hideEmpty: hideEmpty,
            genreMediaType: genreMediaType,
            providers: Array(providers),
            genres: genres.map { KotlinInt(int: $0) }
        )
        onApply(result)
        dismiss()
    }
}

private extension AlbumType {
    var localizationKey: String.LocalizationValue {
        switch self {
        case .album: "album_type_album"
        case .single: "album_type_single"
        case .live: "album_type_live"
        case .soundtrack: "album_type_soundtrack"
        case .compilation: "album_type_compilation"
        case .ep: "album_type_ep"
        default: "album_type_album"
        }
    }
}

private extension MediaType {
    var localizationKey: String.LocalizationValue {
        switch self {
        case .artist: "media_type_artists"
        case .album: "media_type_albums"
        case .track: "media_type_tracks"
        case .playlist: "media_type_playlists"
        case .audiobook: "media_type_audiobooks"
        case .podcast: "media_type_podcasts"
        case .radio: "media_type_radio"
        case .genre: "media_type_genres"
        default: "media_type_artists"
        }
    }
}
