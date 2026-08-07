import SwiftUI
import ComposeApp

/// Result of a bridge fetch.
///
/// The Kotlin fetchers encode three outcomes in one optional: `nil` means the 5s
/// round-trip budget expired (`FETCH_TIMEOUT_MS` in `KmpHelper.kt`), an empty array
/// means the server answered with nothing. Collapsing those into "no results"
/// would show an empty library to someone whose connection simply dropped, so the
/// distinction is preserved all the way to the view.
enum SpikeLoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case timedOut

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Bridges a `KmpHelper` completion fetcher into Swift concurrency.
///
/// Every fetcher shares the shape `(completion: ([AppMediaItem]?) -> Void) -> Void`
/// and guarantees exactly one main-thread callback, which is precisely the
/// contract `withCheckedContinuation` needs. Phase C generalises this into
/// `NativeSuspend`, which additionally propagates cancellation back into Kotlin —
/// the one thing this cannot do.
@MainActor
private func fetchItems(
    _ fetcher: (@escaping ([AppMediaItem]?) -> Void) -> Void
) async -> SpikeLoadState<[SpikeMediaItem]> {
    let raw: [AppMediaItem]? = await withCheckedContinuation { continuation in
        fetcher { items in continuation.resume(returning: items) }
    }
    guard let raw else { return .timedOut }
    return .loaded(raw.asSpikeItems)
}

// MARK: - Library categories

/// The library tabs the spike browses. A deliberate subset — enough to exercise
/// grid layout, list layout, and two levels of drilldown.
enum SpikeCategory: String, CaseIterable, Identifiable {
    case artists, albums, playlists, tracks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        case .tracks: "Tracks"
        }
    }

    var symbol: String {
        switch self {
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .playlists: "music.note.list"
        case .tracks: "music.note"
        }
    }

    /// Grids read well for artwork-forward containers; tracks are a list.
    var prefersGrid: Bool { self != .tracks }

    @MainActor
    func fetch() async -> SpikeLoadState<[SpikeMediaItem]> {
        switch self {
        case .artists: await fetchItems { KmpHelper.shared.fetchArtists(completion: $0) }
        case .albums: await fetchItems { KmpHelper.shared.fetchAlbums(completion: $0) }
        case .playlists: await fetchItems { KmpHelper.shared.fetchPlaylists(completion: $0) }
        case .tracks: await fetchItems { KmpHelper.shared.fetchTracks(completion: $0) }
        }
    }
}

@Observable
@MainActor
final class SpikeLibraryStore {

    private(set) var states: [SpikeCategory: SpikeLoadState<[SpikeMediaItem]>] = [:]

    func state(for category: SpikeCategory) -> SpikeLoadState<[SpikeMediaItem]> {
        states[category] ?? .idle
    }

    /// Loads a category unless it already holds results. Pass `force` for pull-to-refresh.
    func load(_ category: SpikeCategory, force: Bool = false) async {
        if !force, state(for: category).value != nil { return }
        states[category] = .loading
        states[category] = await category.fetch()
    }
}

// MARK: - Drilldown

@Observable
@MainActor
final class SpikeDetailStore {

    private(set) var children: SpikeLoadState<[SpikeMediaItem]> = .idle

    /// Fetches the children of a browsable item. Returns `.loaded([])` for kinds
    /// that have no drilldown, so callers need no special case.
    func load(for item: SpikeMediaItem) async {
        guard children.value == nil else { return }
        children = .loading

        children = switch item.kotlin {
        case let artist as Artist:
            await fetchItems { KmpHelper.shared.fetchAlbumsByArtist(artist: artist, completion: $0) }
        case let album as Album:
            await fetchItems { KmpHelper.shared.fetchTracksByAlbum(album: album, completion: $0) }
        case let playlist as Playlist:
            await fetchItems { KmpHelper.shared.fetchTracksByPlaylist(playlist: playlist, completion: $0) }
        case let podcast as Podcast:
            await fetchItems { KmpHelper.shared.fetchEpisodesByPodcast(podcast: podcast, completion: $0) }
        default:
            .loaded([])
        }
    }
}

// MARK: - Search

@Observable
@MainActor
final class SpikeSearchStore {

    private(set) var results: SpikeLoadState<[SpikeMediaItem]> = .idle

    private var searchTask: Task<Void, Never>?

    /// Debounced so typing does not fire a round trip per keystroke. The Kotlin
    /// `LibraryListViewModel` owns this policy for the real app; the spike
    /// reproduces just enough of it to make `.searchable` feel right.
    func search(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = .idle
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            results = .loading
            let outcome = await fetchItems { KmpHelper.shared.search(query: trimmed, completion: $0) }
            guard !Task.isCancelled else { return }
            results = outcome
        }
    }

    func clear() {
        searchTask?.cancel()
        results = .idle
    }
}

// MARK: - Playback

enum SpikePlayback {

    /// Dispatches onto the iOS local Sendspin player via the same path CarPlay uses.
    /// Returns false when there is no local player or no playable URI.
    @discardableResult
    static func play(_ item: SpikeMediaItem, option: QueueOption = .play) -> Bool {
        KmpHelper.shared.playOnLocalPlayer(item: item.kotlin, option: option)
    }

    @discardableResult
    static func setFavorite(_ item: SpikeMediaItem, _ favorite: Bool) -> Bool {
        KmpHelper.shared.setFavorite(item: item.kotlin, favorite: favorite)
    }

    /// Starts a radio seeded from the item. Goes through the named-action path
    /// rather than `playOnLocalPlayer`, which hardcodes `radioMode = false`.
    @discardableResult
    static func startRadio(_ item: SpikeMediaItem) -> Bool {
        KmpHelper.shared.playCarAction(item: item.kotlin, actionName: "START_RADIO")
    }
}
