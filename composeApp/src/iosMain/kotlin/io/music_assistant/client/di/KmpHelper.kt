@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package io.music_assistant.client.di

import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.readRawBytes
import io.ktor.http.Url
import io.music_assistant.client.api.DeepLinkBus
import io.music_assistant.client.api.DeepLinkDestination
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.auth.AuthenticationManager
import io.music_assistant.client.bridge.Cancellable
import io.music_assistant.client.bridge.NativeStateFlow
import io.music_assistant.client.carplay.CarPlayStrings
import io.music_assistant.client.data.MainDataSource
import io.music_assistant.client.data.NowPlayingModes
import io.music_assistant.client.data.NowPlayingTrack
import io.music_assistant.client.data.NowPlayingTransport
import io.music_assistant.client.data.executeLocalPlayerDispatch
import io.music_assistant.client.data.model.client.LibraryFilters
import io.music_assistant.client.data.model.client.MediaType
import io.music_assistant.client.data.model.client.QueueOption
import io.music_assistant.client.data.model.client.SortConfig
import io.music_assistant.client.data.model.client.SortOption
import io.music_assistant.client.data.model.client.SubItemContext
import io.music_assistant.client.data.model.client.clientSorted
import io.music_assistant.client.data.model.client.items.Album
import io.music_assistant.client.data.model.client.items.AppMediaItem
import io.music_assistant.client.data.model.client.items.Artist
import io.music_assistant.client.data.model.client.items.Genre
import io.music_assistant.client.data.model.client.items.Playlist
import io.music_assistant.client.data.model.client.items.Podcast
import io.music_assistant.client.data.model.client.items.PodcastEpisode
import io.music_assistant.client.data.model.client.items.RecommendationFolder
import io.music_assistant.client.data.model.client.items.Track
import io.music_assistant.client.data.model.client.toItemKind
import io.music_assistant.client.data.model.server.ServerProviderInstance
import io.music_assistant.client.data.planLocalPlayerDispatch
import io.music_assistant.client.data.repository.MediaItemRepository
import io.music_assistant.client.input.VolumeButtonService
import io.music_assistant.client.settings.CarPlatform
import io.music_assistant.client.settings.DefaultClickOption
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.settings.carBulkActions
import io.music_assistant.client.settings.carTapAction
import io.music_assistant.client.settings.toCarDispatch
import io.music_assistant.client.ui.AppBannerState
import io.music_assistant.client.ui.AppRootDestination
import io.music_assistant.client.ui.AppRootRouter
import io.music_assistant.client.ui.SchemaVersionWarningViewModel
import io.music_assistant.client.ui.SchemaWarning
import io.music_assistant.client.ui.compose.item.ItemUseCases
import io.music_assistant.client.ui.compose.library.LibraryCategory
import io.music_assistant.client.ui.compose.library.carTabCategories
import io.music_assistant.client.utils.HasConnectionData
import io.music_assistant.client.utils.currentTimeMillis
import io.music_assistant.client.utils.resultAs
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.koin.core.component.KoinComponent
import org.koin.core.component.inject
import org.koin.core.qualifier.named
import platform.Foundation.NSData
import platform.Foundation.create

private val log = Logger.withTag("KmpHelper")

/** CarPlay round-trip budget before a fetch surfaces a disconnected affordance. */
private const val FETCH_TIMEOUT_MS = 5_000L

/** See [fetchTracks]. */
private const val TRACKS_FETCH_LIMIT = 500

/** See [fetchLibraryItems]. Matches LibraryListViewModel.PAGE_SIZE. */
private const val LIBRARY_PAGE_SIZE = 50

/** A provider entry for the library filter sheet's provider picker. See [KmpHelper.fetchLibraryProviderOptions]. */
data class LibraryProviderOption(val instanceId: String, val label: String)

/** A genre entry for the library filter sheet's genre picker. See [KmpHelper.fetchLibraryGenreOptions]. */
data class LibraryGenreOption(val genreId: Int, val label: String)

/**
 * KmpHelper - Bridge for accessing Koin dependencies from Swift
 */
object KmpHelper : KoinComponent {
    val mainDataSource: MainDataSource by inject()
    val serviceClient: ServiceClient by inject()
    val authManager: AuthenticationManager by inject()
    private val appRootRouter: AppRootRouter by inject()
    private val schemaVersionWarningViewModel: SchemaVersionWarningViewModel by inject()
    private val deepLinkBus: DeepLinkBus by inject()
    private val mediaItemRepository: MediaItemRepository by inject()
    private val settingsRepository: SettingsRepository by inject()
    private val volumeButtonService: VolumeButtonService by inject()
    private val artworkHttpClient: HttpClient by inject(named("webrtcHttpClient"))

    // Provide a scope for Swift to launch coroutines if needed
    val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // MARK: - App root (Phase C SwiftUI shell)
    //
    // Drives the top-level switch AppRouter.swift owns: which screen (Main tab
    // shell vs. Settings), the cold-launch auto-login splash, and the
    // reconnection banner. All policy lives in AppRootRouter (commonMain) —
    // these are thin NativeStateFlow projections, not reimplementations.

    val rootDestination: NativeStateFlow<AppRootDestination>
        get() = NativeStateFlow(appRootRouter.destination, mainScope)

    val splashVisible: NativeStateFlow<Boolean>
        get() = NativeStateFlow(appRootRouter.splashVisible, mainScope)

    val connectionBannerState: NativeStateFlow<AppBannerState>
        get() = NativeStateFlow(appRootRouter.bannerState, mainScope)

    fun cancelAutoLogin() = appRootRouter.cancelAutoLogin()
    fun requestSettings() = appRootRouter.requestSettings()
    fun requestHome() = appRootRouter.requestHome()

    // MARK: - Schema compatibility warning
    //
    // Same "shared Kotlin policy, thin Swift projection" shape as the app-root
    // properties above. SchemaVersionWarningViewModel became a Koin single
    // (see SharedModule.kt) specifically so this and App.kt's Compose dialog
    // read the same instance rather than each getting their own.

    val schemaWarning: NativeStateFlow<SchemaWarning>
        get() = NativeStateFlow(schemaVersionWarningViewModel.warning, mainScope)

    // MARK: - Deep links
    //
    // Not yet consumed from Swift — MainNavRoot.kt's own DeepLinkBus
    // collection is still what handles these, because it still owns in-tree
    // navigation for the Main destination (see ComposeScreenHosts.kt's doc).
    // Exposed here for when Swift takes over that navigation.

    val deepLinks: NativeStateFlow<DeepLinkDestination>
        get() = NativeStateFlow(deepLinkBus.pending, mainScope)

    fun consumeDeepLink(destination: DeepLinkDestination) = deepLinkBus.consume(destination)

    /**
     * The connected MA server's stable identifier (UUID-style, e.g.
     * "70e548..."). Available once the server has sent its handshake;
     * null while the connection is still being established.
     */
    fun getServerId(): String? {
        return (serviceClient.sessionState.value as? HasConnectionData)
            ?.connectionData
            ?.serverInfo
            ?.serverId
    }

    /**
     * Route a `musicassistant://app/<page>` URL into the navigation deep-link
     * bus. Parsing/validation lives in [DeepLinkBus]; non-matching URLs are
     * silently ignored.
     */
    fun handleDeepLink(urlString: String) = deepLinkBus.handle(urlString)

    fun onPlatformVolumeButtonPressed() {
        volumeButtonService.onPlatformVolumeButtonPressed()
    }

    // MARK: - External Consumer Lifecycle (CarPlay)

    /**
     * Resolve CarPlay UI strings for the current locale off the shared Compose
     * catalog. Async because the resource read is suspending; CarPlay defers
     * building its first template until [completion] fires so immutable
     * template titles are never blank.
     */
    fun loadCarPlayStrings(completion: (CarPlayStrings) -> Unit) {
        mainScope.launch { completion(CarPlayStrings.load()) }
    }

    fun onExternalConsumerActive() = serviceClient.onExternalConsumerActive()
    fun onExternalConsumerInactive() = serviceClient.onExternalConsumerInactive()

    // MARK: - Artwork loader (Swift-callable)
    //
    // Swift CarPlay / MPNowPlayingInfoCenter previously fetched artwork through
    // `URLSession.shared.dataTask(...)`. That bypasses the WebRTC data-channel proxy
    // (URLSession can't speak `mawebrtc://`) and breaks lock-screen / CarPlay artwork
    // whenever the URL we hand Swift is a synthetic proxy URL. This helper routes:
    //   - `mawebrtc://...` → `WebRTCHttpProxy.get(...)` (returns hex-decoded bytes)
    //   - `http(s)://...`  → Ktor GET
    // Swift consumes the NSData and builds the UIImage.
    fun loadArtworkBytes(
        urlString: String,
        completion: (NSData?) -> Unit,
    ): Cancellable {
        val job = mainScope.launch {
            val bytes = try {
                fetchArtworkInternal(urlString)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                log.w { "loadArtworkBytes failed for $urlString: ${e.message}" }
                null
            }
            completion(bytes?.toNSData())
        }
        return Cancellable { job.cancel() }
    }

    private suspend fun fetchArtworkInternal(urlString: String): ByteArray? = when {
        urlString.startsWith("mawebrtc://") -> {
            val proxy = serviceClient.webRTCHttpProxy ?: return null
            val parsed = Url(urlString)
            val tail = parsed.encodedQuery.let { q ->
                if (q.isEmpty()) parsed.encodedPath else "${parsed.encodedPath}?$q"
            }
            val response = proxy.get(tail)
            response.body.takeIf { response.status in 200..299 }
        }
        urlString.startsWith("http://") || urlString.startsWith("https://") -> {
            val response = artworkHttpClient.get(urlString)
            response.readRawBytes().takeIf { response.status.value in 200..299 }
        }
        else -> null
    }

    private fun ByteArray.toNSData(): NSData {
        if (isEmpty()) return NSData()
        return usePinned { pinned ->
            NSData.create(bytes = pinned.addressOf(0), length = size.toULong())
        }
    }

    // MARK: - Readiness observation

    /**
     * Subscribe to transport command-readiness. Fires with the current value
     * on subscribe and on every change.
     */
    fun observeReadiness(onChanged: (Boolean) -> Unit): Cancellable {
        val job = mainScope.launch {
            serviceClient.isReadyForCommands.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    // MARK: - Now Playing channels
    //
    // Per-concern state for the system media UI (lock screen / Control Center /
    // CarPlay). Each observer replays the current value on subscribe — late
    // subscribers (CarPlay connecting mid-playback, foreground return) catch up
    // immediately. Callbacks arrive on the main thread; Swift needs no dispatch
    // hop. `null` means "nothing to present" (no current track).

    /**
     * Subscribe to track metadata changes (identity, titles, artwork URL,
     * duration, long-form flag).
     */
    fun observeNowPlayingTrack(onChanged: (NowPlayingTrack?) -> Unit): Cancellable {
        val job = mainScope.launch {
            mainDataSource.nowPlayingTrack.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    /**
     * Subscribe to transport anchor changes (playing state, position anchor,
     * rate). The anchor timestamp is only meaningful on the Kotlin side;
     * Swift re-stamps arrival with its own clock.
     */
    fun observeNowPlayingTransport(onChanged: (NowPlayingTransport?) -> Unit): Cancellable {
        val job = mainScope.launch {
            mainDataSource.nowPlayingTransport.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    /** Subscribe to queue-mode changes (shuffle, repeat, toggle availability). */
    fun observeNowPlayingModes(onChanged: (NowPlayingModes?) -> Unit): Cancellable {
        val job = mainScope.launch {
            mainDataSource.nowPlayingModes.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    // MARK: - Swift Helpers for Data Fetching
    //
    // Every fetcher returns a nullable list. `null` means the round trip
    // exceeded FETCH_TIMEOUT_MS — Swift renders a disconnected affordance.
    // An empty list means the server answered with nothing.

    private inline fun <T> launchFetch(
        label: String,
        crossinline completion: (List<T>?) -> Unit,
        crossinline fetch: suspend () -> List<T>,
    ) {
        val startMs = currentTimeMillis()
        log.i { "fetch[$label] start" }
        mainScope.launch {
            val items: List<T>? = withTimeoutOrNull(FETCH_TIMEOUT_MS) { fetch() }
            val elapsed = currentTimeMillis() - startMs
            if (items == null) {
                log.i { "fetch[$label] timeout after ${elapsed}ms" }
            } else {
                log.i { "fetch[$label] returned ${items.size} items in ${elapsed}ms" }
            }
            completion(items)
        }
    }

    fun fetchRecommendations(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("recommendations", completion) {
            mediaItemRepository.fetchRecommendationFolders().getOrNull()
                ?: emptyList()
        }
    }

    fun fetchRecommendationFolders(
        completion: (List<RecommendationFolder>?) -> Unit,
    ) {
        launchFetch("recommendationFolders", completion) {
            mediaItemRepository.fetchRecommendationFolders().getOrNull()
                ?: emptyList()
        }
    }

    fun fetchPlaylists(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("playlists", completion) {
            mediaItemRepository.fetchMediaItems(Request.Playlist.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchAlbums(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("albums", completion) {
            mediaItemRepository.fetchMediaItems(Request.Album.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchArtists(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("artists", completion) {
            mediaItemRepository.fetchMediaItems(Request.Artist.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchAudiobooks(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("audiobooks", completion) {
            mediaItemRepository.fetchMediaItems(Request.Audiobook.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    /**
     * Capped, unlike every other `fetchX` in this file: a track library is routinely the
     * largest catalog in the app (often thousands of rows, versus dozens-to-hundreds of
     * artists/albums/playlists), and LibraryListView.swift has no pagination yet. Fetching
     * it unbounded (the `Int.MAX_VALUE` default) was observed to make the round trip +
     * decode large enough that the simulator's own background/foreground lifecycle
     * spuriously fired mid-request, cancelling it — `TRACKS_FETCH_LIMIT` keeps the request
     * small enough that this doesn't happen while native search/pagination isn't built yet.
     */
    fun fetchTracks(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("tracks", completion) {
            mediaItemRepository.fetchMediaItems(Request.Track.list(limit = TRACKS_FETCH_LIMIT)).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchPodcasts(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("podcasts", completion) {
            mediaItemRepository.fetchMediaItems(Request.Podcast.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchRadioStations(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("radioStations", completion) {
            mediaItemRepository.fetchMediaItems(Request.RadioStation.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchGenres(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("genres", completion) {
            mediaItemRepository.fetchMediaItems(Request.Genre.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    /**
     * LibraryListView.swift's single entry point, in place of the eight fetchX above:
     * one method covering every category, with the `search`/`offset`/`sortOption`/
     * `filters` params those don't take. Mirrors LibraryListViewModel.getRequest's
     * per-type dispatch exactly, [filters] included.
     *
     * [offset] + the fixed [LIBRARY_PAGE_SIZE] page is LibraryListViewModel's own
     * offset+limit paging, not a cursor: Swift passes `0` for a fresh load (a route,
     * query, sort, or filter change) and `items.count` to fetch the next page, and
     * treats `result.count >= LIBRARY_PAGE_SIZE` as "there may be more" — same
     * heuristic as `updateStateWithData`'s `hasMore`. `TRACK` no longer needs its own
     * `TRACKS_FETCH_LIMIT`: real pagination caps every request at `LIBRARY_PAGE_SIZE`
     * regardless of type, so the unbounded-fetch problem that constant was working
     * around ([fetchTracks]'s doc) doesn't arise here.
     */
    fun fetchLibraryItems(
        mediaType: MediaType,
        search: String?,
        offset: Int,
        sortOption: SortOption,
        filters: LibraryFilters,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        val orderBy = sortOption.toServerString()
        val favorite = filters.favorite.takeIf { it }
        val providers = filters.providers.takeIf { it.isNotEmpty() }
        val genres = filters.genres.takeIf { it.isNotEmpty() }
        val request = when (mediaType) {
            MediaType.ARTIST -> Request.Artist.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, albumArtistsOnly = filters.albumArtistsOnly,
                providers = providers, genres = genres,
            )
            MediaType.ALBUM -> Request.Album.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, albumTypes = filters.albumTypes.map { it.serverValue },
                providers = providers, genres = genres,
            )
            MediaType.TRACK -> Request.Track.list(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.PLAYLIST -> Request.Playlist.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.AUDIOBOOK -> Request.Audiobook.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.PODCAST -> Request.Podcast.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.RADIO -> Request.RadioStation.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.GENRE -> Request.Genre.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers,
                hideEmpty = filters.hideEmpty.hideEmpty, mediaType = filters.genreMediaType?.serverValue,
            )
            else -> null
        } ?: return completion(emptyList())

        launchFetch("libraryItems:$mediaType:${search.orEmpty()}:$offset:$orderBy:$filters", completion) {
            mediaItemRepository.fetchMediaItems(request).getOrNull() ?: emptyList()
        }
    }

    /**
     * The current persisted [LibraryFilters] for [mediaType], live — mirrors
     * `LibraryListViewModel`'s fold of `settingsRepository.libraryFilters(mediaType)`
     * into its own state. Drives both the filter sheet's initial working copy and the
     * toolbar filter button's active tint (`LibraryFilters.hasActive`, callable
     * directly from Swift as a Kotlin extension property).
     */
    fun libraryFilters(mediaType: MediaType): NativeStateFlow<LibraryFilters> =
        NativeStateFlow(settingsRepository.libraryFilters(mediaType), mainScope)

    /** Persists [filters] for [mediaType] — settings are the source of truth, same as Compose's `setFilters`. */
    fun setLibraryFilters(mediaType: MediaType, filters: LibraryFilters) {
        settingsRepository.setLibraryFilters(mediaType, filters)
    }

    /**
     * Library capability a provider must declare to be offered as a provider-filter option
     * on [mediaType]'s list. Null for types with no provider filter (GENRE). Mirrors
     * LibraryListViewModel.providerFeatureFor exactly.
     */
    private fun providerFeatureFor(mediaType: MediaType): String? = when (mediaType) {
        MediaType.ARTIST -> "library_artists"
        MediaType.ALBUM -> "library_albums"
        MediaType.TRACK -> "library_tracks"
        MediaType.PLAYLIST -> "library_playlists"
        MediaType.RADIO -> "library_radios"
        MediaType.PODCAST -> "library_podcasts"
        MediaType.AUDIOBOOK -> "library_audiobooks"
        else -> null
    }

    /**
     * Provider options for the filter sheet's provider picker — mirrors
     * LibraryListViewModel.loadProviderOptions. Empty (not `null`) for GENRE, which has
     * no provider filter, same as the Compose sheet skipping the load entirely there.
     */
    fun fetchLibraryProviderOptions(mediaType: MediaType, completion: (List<LibraryProviderOption>?) -> Unit) {
        val feature = providerFeatureFor(mediaType) ?: return completion(emptyList())
        launchFetch("libraryProviderOptions:$mediaType", completion) {
            val providers = serviceClient.sendRequest(Request.Library.providers())
                .resultAs<List<ServerProviderInstance>>()
            providers
                ?.filter { it.type == "music" && it.available && feature in it.supportedFeatures }
                ?.map { LibraryProviderOption(it.instanceId, it.name ?: it.domain ?: it.instanceId) }
                ?.sortedBy { it.label.lowercase() }
                ?: emptyList()
        }
    }

    /**
     * Genre options for the filter sheet's genre picker, scoped to genres that actually
     * contain items of [mediaType] — mirrors LibraryListViewModel.loadGenreOptions.
     */
    fun fetchLibraryGenreOptions(mediaType: MediaType, completion: (List<LibraryGenreOption>?) -> Unit) {
        launchFetch("libraryGenreOptions:$mediaType", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Genre.listLibrary(limit = 1000, orderBy = "sort_name", mediaType = mediaType.serverValue),
            ).getOrNull()
                ?.filterIsInstance<Genre>()
                ?.mapNotNull { g -> g.itemId.toIntOrNull()?.let { LibraryGenreOption(it, g.displayName) } }
                ?: emptyList()
        }
    }

    /**
     * One level of the server's `music/browse` provider tree, for the native BrowseView —
     * mirrors `BrowseViewModel.load`. `path`: null for the root, or a `RecommendationFolder`'s
     * `path` (falling back to its `uri`) to descend one level, exactly as
     * `MainNav.Browse(path = item.path ?: item.uri, …)` does on the Compose side. The server
     * returns the whole level in one shot — no pagination here, matching BrowseViewModel's own
     * doc comment.
     */
    fun fetchBrowseItems(path: String?, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("browse:${path ?: "root"}", completion) {
            mediaItemRepository.fetchMediaItems(Request.Browse.atPath(path)).getOrNull()
                ?: emptyList()
        }
    }

    fun search(query: String, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("search:$query", completion) {
            val result = mediaItemRepository.search(
                Request.Library.search(
                    query = query,
                    mediaTypes = listOf(
                        MediaType.ARTIST,
                        MediaType.ALBUM,
                        MediaType.TRACK,
                        MediaType.PLAYLIST,
                        MediaType.AUDIOBOOK,
                        MediaType.RADIO,
                    ),
                    limit = 10,
                    libraryOnly = false,
                ),
            ).getOrNull()
            buildList<AppMediaItem> {
                result ?: return@buildList
                addAll(result.artists)
                addAll(result.albums)
                addAll(result.tracks)
                addAll(result.playlists)
                addAll(result.podcasts)
                addAll(result.audiobooks)
                addAll(result.radios)
                addAll(result.genres)
            }
        }
    }

    // MARK: - Drilldown fetchers (same nullable-on-timeout contract)

    fun fetchAlbumsByArtist(
        artist: Artist,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("albumsByArtist:${artist.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Artist.getAlbums(
                    itemId = artist.itemId,
                    providerInstanceIdOrDomain = artist.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<Album>()
                ?: emptyList()
        }
    }

    fun fetchTracksByAlbum(
        album: Album,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("tracksByAlbum:${album.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Album.getTracks(
                    itemId = album.itemId,
                    providerInstanceIdOrDomain = album.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<Track>()
                ?: emptyList()
        }
    }

    fun fetchTracksByPlaylist(
        playlist: Playlist,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("tracksByPlaylist:${playlist.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Playlist.getTracks(
                    itemId = playlist.itemId,
                    providerInstanceIdOrDomain = playlist.provider,
                    forceRefresh = null,
                ),
            ).getOrNull()
                ?.filterIsInstance<Track>()
                ?: emptyList()
        }
    }

    fun fetchEpisodesByPodcast(
        podcast: Podcast,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("episodesByPodcast:${podcast.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Podcast.getEpisodes(
                    itemId = podcast.itemId,
                    providerInstanceIdOrDomain = podcast.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<PodcastEpisode>()
                ?.clientSorted(
                    SortConfig.defaultFor(SubItemContext.PODCAST_EPISODES),
                    SubItemContext.PODCAST_EPISODES,
                )
                ?: emptyList()
        }
    }

    /**
     * The "Discography" section of the native artist screen — an album list assembled by
     * trying the artist's provider mappings in order and keeping the first non-empty result,
     * same as `ItemDetailsViewModel.loadArtistAlbumSections`'s `all` section. `null` on
     * timeout or when the artist has no provider mappings at all.
     */
    fun fetchArtistAllAlbums(artist: Artist, completion: (List<AppMediaItem>?) -> Unit) {
        mainScope.launch {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                ItemUseCases.fetchArtistItemsAcrossProviders<Album>(mediaItemRepository, artist) {
                        itemId, providerInstance ->
                    Request.Artist.getAlbums(itemId, providerInstance)
                }
            }
            completion(result?.items)
        }
    }

    /** The "Top tracks" section of the native artist screen — same cross-provider contract
     * as [fetchArtistAllAlbums]. */
    fun fetchArtistTopTracks(artist: Artist, completion: (List<AppMediaItem>?) -> Unit) {
        mainScope.launch {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                ItemUseCases.fetchArtistItemsAcrossProviders<Track>(mediaItemRepository, artist) {
                        itemId, providerInstance ->
                    Request.Artist.getTopTracks(itemId, providerInstance)
                }
            }
            completion(result?.items)
        }
    }

    /** Lazily fetched from the artist screen's "Similar artists" sheet, mirroring
     * `ItemDetailsViewModel.loadSimilarArtists`'s request shape. */
    fun fetchSimilarArtists(artist: Artist, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("similarArtists:${artist.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Artist.getSimilarArtists(
                    itemId = artist.itemId,
                    providerInstanceIdOrDomain = artist.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<Artist>()
                ?: emptyList()
        }
    }

    /**
     * The native genre screen's Albums/Artists overview — a mixed list Swift filters by type,
     * mirroring `ItemDetailsViewModel.loadGenreOverview`'s flattening of the server's
     * recommendation folders.
     */
    fun fetchGenreOverview(itemId: String, providerId: String, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("genreOverview:$itemId", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Genre.overview(
                    itemId = itemId,
                    providerInstanceIdOrDomain = providerId,
                ),
            ).getOrNull()
                ?.filterIsInstance<RecommendationFolder>()
                ?.flatMap { it.items.orEmpty() }
                ?: emptyList()
        }
    }

    /**
     * Fetches a single item (Album/Playlist/Podcast/Audiobook/Artist/Genre) by identity, for
     * the native ItemDetailsView hero — mirrors ItemDetailsViewModel.getItemById's request
     * shape. `null` on both an unsupported type and a timed-out/failed fetch — the caller
     * can't tell those apart, but it only needs "show the error state".
     */
    fun fetchItemDetails(
        itemId: String,
        mediaType: MediaType,
        providerId: String,
        completion: (AppMediaItem?) -> Unit,
    ) {
        val request = when (mediaType) {
            MediaType.ALBUM -> Request.Album.get(itemId, providerId)
            MediaType.PLAYLIST -> Request.Playlist.get(itemId, providerId)
            MediaType.PODCAST -> Request.Podcast.get(itemId, providerId)
            MediaType.AUDIOBOOK -> Request.Audiobook.get(itemId, providerId)
            MediaType.ARTIST -> Request.Artist.get(itemId, providerId)
            MediaType.GENRE -> Request.Genre.get(itemId, providerId)
            else -> null
        } ?: return completion(null)

        launchFetchSingle("itemDetails:$mediaType:$itemId", completion) {
            mediaItemRepository.fetchMediaItem(request).getOrNull()
        }
    }

    private inline fun <T> launchFetchSingle(
        label: String,
        crossinline completion: (T?) -> Unit,
        crossinline fetch: suspend () -> T?,
    ) {
        val startMs = currentTimeMillis()
        mainScope.launch {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) { fetch() }
            log.i { "fetch[$label] ${if (result != null) "loaded" else "failed"} in ${currentTimeMillis() - startMs}ms" }
            completion(result)
        }
    }

    // MARK: - Playback

    /**
     * Play, replace, or append [item] on the iOS local Sendspin player —
     * never the group it may be synced to. When the local player is currently
     * a sync-group child we always detach first, regardless of [option]:
     * being in CarPlay means the user wants audio out of the phone they're
     * holding, and there's no plausible scenario where they want the same
     * audio mirrored to another player as well.
     *
     * Returns false on no-local-player or no-URI; callers use this to skip
     * Siri donation and respond with `.failure`.
     */
    fun playOnLocalPlayer(item: AppMediaItem, option: QueueOption): Boolean =
        dispatchLocal(item, option, radioMode = false)

    private fun dispatchLocal(item: AppMediaItem, option: QueueOption, radioMode: Boolean): Boolean {
        val player = mainDataSource.localPlayer.value?.player
        val plan = planLocalPlayerDispatch(
            localPlayerId = player?.id,
            localPlayerSyncedTo = player?.syncedTo,
            mediaUris = listOfNotNull(item.mediaUri),
            option = option,
            radioMode = radioMode,
        ) ?: return false
        plan.detachFrom?.let { syncedToId ->
            log.i { "dispatchLocal($option, radio=$radioMode): detaching ${plan.playerId} from $syncedToId" }
        }
        mainScope.launch {
            executeLocalPlayerDispatch(serviceClient, plan) { label, error ->
                log.w(error) { "$label RPC failed: ${error.message}" }
            }
        }
        return true
    }

    /**
     * Play [item] on whichever player is currently selected (the Home tab's player
     * picker) — not necessarily this device, unlike [playOnLocalPlayer], which is
     * CarPlay's deliberate always-local override. Mirrors
     * `ItemDetailsViewModel.onPlayClick`'s request shape for the native ItemDetailsView's
     * hero play button and track/episode row taps. False on no selected player or no URI.
     */
    fun playOnSelectedPlayer(item: AppMediaItem, option: QueueOption, radio: Boolean): Boolean {
        val mediaUri = item.mediaUri ?: return false
        val queueId = mainDataSource.selectedPlayer?.queueOrPlayerId ?: return false
        mainScope.launch {
            serviceClient.sendRequest(
                Request.Library.play(
                    media = listOf(mediaUri),
                    queueOrPlayerId = queueId,
                    option = option,
                    radioMode = radio && item !is Genre,
                ),
            )
        }
        return true
    }

    /**
     * Plays an audiobook [item] starting at [chapterPosition], on the currently selected
     * player. Mirrors `ItemDetailsViewModel.onChapterClick`.
     */
    fun playChapterOnSelectedPlayer(item: AppMediaItem, chapterPosition: Int): Boolean {
        val uri = item.uri ?: return false
        val queueId = mainDataSource.selectedPlayer?.queueOrPlayerId ?: return false
        mainScope.launch {
            serviceClient.sendRequest(
                Request.Library.play(
                    media = listOf(uri),
                    queueOrPlayerId = queueId,
                    option = QueueOption.REPLACE,
                    radioMode = false,
                    startItem = chapterPosition.toString(),
                ),
            )
        }
        return true
    }

    // MARK: - Configurable Car actions (shared with Android Auto via SettingsRepository)

    /**
     * The ordered, CarPlay-supported bulk-action names (DefaultClickAction.name) configured for
     * [item]'s browsable kind. Empty when the item isn't a browsable container. Swift maps each
     * name to a localized title (CarPlayStrings.bulkActionTitle) and dispatches via [playCarAction].
     */
    fun carBulkActionNames(item: AppMediaItem): List<String> {
        val kind = item.mediaType.toItemKind() ?: return emptyList()
        return settingsRepository.carBrowsableBulkActions.value
            .carBulkActions(kind, CarPlatform.CARPLAY)
            .map { it.name }
    }

    /** Dispatch a named [DefaultClickOption] (a bulk button) onto [item]. False if invalid/no-op. */
    fun playCarAction(item: AppMediaItem, actionName: String): Boolean {
        val action = runCatching { DefaultClickOption.valueOf(actionName) }.getOrNull() ?: return false
        val dispatch = action.toCarDispatch()
        return dispatchLocal(item, dispatch.option, dispatch.radioMode)
    }

    /**
     * Dispatch the per-kind tap action configured for [item] (a plain item tap). Returns the
     * dispatched DefaultClickAction.name so Swift can decide whether to push Now Playing, or null
     * on failure / no playable URI.
     */
    fun playCarDefaultTap(item: AppMediaItem): String? {
        val action = item.mediaType.toItemKind()
            ?.let { settingsRepository.carPlayableClickActions.value.carTapAction(it) }
            ?: DefaultClickOption.PLAY_NOW
        val dispatch = action.toCarDispatch()
        return if (dispatchLocal(item, dispatch.option, dispatch.radioMode)) action.name else null
    }

    /**
     * The ordered, enabled CarPlay browse-grid categories from the user's Car Tabs setting.
     * Returns LibraryCategory.name strings (e.g. "ARTISTS", "ALBUMS") so Swift can map each
     * to its fetcher and icon. Falls back to [carTabCategories] when no config is stored.
     * Tracks and Genres are excluded because they are not in [carTabCategories].
     */
    fun carBrowseCategories(): List<String> {
        val stored = settingsRepository.carTabsConfig.value
            ?: return carTabCategories.map { it.name }
        val parsed = stored.mapNotNull { pref ->
            runCatching { LibraryCategory.valueOf(pref.name) }.getOrNull()
                ?.takeIf { it in carTabCategories }
                ?.let { it to pref.enabled }
        }
        val present = parsed.map { it.first }.toSet()
        val missing = carTabCategories.filter { it !in present }.map { it to true }
        return (parsed + missing)
            .filter { (_, enabled) -> enabled }
            .map { (category, _) -> category.name }
    }

    // MARK: - Library Actions (Siri)

    /**
     * Set the favorite flag on an [AppMediaItem]. Drives `INMediaAffinityIntent`
     * mapping from Swift: `like` ⇒ `favorite = true`, `dislike` ⇒ `favorite = false`.
     * MA only tracks favorites as a boolean — dislike removes an existing favorite
     * but cannot record an explicit "do not play this" signal. Adding requires a
     * URI; removal works by id+mediaType.
     *
     * Returns `true` synchronously when the request was dispatched, `false` when
     * we couldn't form a valid request (the only known failure mode today: an
     * add for an item with no URI). Network outcome is fire-and-forget — Swift
     * uses the synchronous return to avoid lying to Siri about success.
     */
    fun setFavorite(item: AppMediaItem, favorite: Boolean): Boolean {
        if (favorite) {
            // Prefer plain `uri`; fall back to `mediaUri`. The base class uses
            // `uri` directly; subclasses like Genre override `mediaUri` to
            // synthesize one when the server didn't supply it.
            val uri = item.uri ?: item.mediaUri ?: return false
            mainScope.launch {
                serviceClient.sendRequest(Request.Library.addFavorite(uri))
            }
        } else {
            mainScope.launch {
                serviceClient.sendRequest(
                    Request.Library.removeFavorite(item.itemId, item.mediaType),
                )
            }
        }
        return true
    }
}
