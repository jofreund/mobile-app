import SwiftUI
import MusicAssistantKit

/// The Home tab's root — Phase E5, part 1. Reimplements only `HomeScreen.kt`'s row content
/// natively (a vertical list of horizontal recommendation/shortcut carousels, plus edit mode);
/// the floating player bar (`PlayersPager`/`FloatingBar`) stays Compose-hosted via
/// `FloatingBarCollapsedController`/`FloatingBarExpandedController` — see `AppTabView.swift`'s
/// doc — since a full native rewrite of that gesture-heavy UI is its own, much larger, separately
/// scoped piece of work.
///
/// `HomeScreenViewModel` is deliberately **not** wrapped the way `AppRootRouter` was
/// (`AppRouter.swift`'s `NativeFlow`-subscription pattern): its real complexity — the
/// session/connection state machine, job lifecycle, live `itemChanges` patching — is about
/// *when* to show loading/reconnecting states, not about producing this screen's row data.
/// That data is two one-shot server round trips (`KmpHelper.fetchRecommendationFolders`,
/// `KmpHelper.fetchShortcuts`, both mirroring `HomeScreenViewModel.loadData()` exactly), so this
/// screen fetches on appear/refresh like every other native screen so far (`LibraryListView`,
/// `SearchView`) rather than subscribing to a continuously-reactive Kotlin state machine.
struct HomeView: View {

    @State private var recommendations: [RecommendationFolder]?
    @State private var shortcuts: [AppMediaItem]?
    @State private var loadFailed = false
    @State private var reloadTrigger = UUID()
    @State private var sessionSubscription: Cancellable?
    @State private var wasReady = false

    @State private var homeRowsConfig: [SettingsRepository.HomeRowPref] = []
    @State private var isEditing = false
    @State private var editingEnabledRows: [HomeRow] = []
    @State private var editingDisabledRows: [HomeRow] = []

    /// Rows the server + shortcuts resolved to, reconciled against persisted enabled/order
    /// prefs — recomputed whenever the fetch or the persisted config changes. `nil` only until
    /// the *first* load succeeds: later loads leave the last good rows in place, so a refresh
    /// (or a failed one) never empties the screen.
    private var rows: [(row: HomeRow, enabled: Bool)]? {
        guard let recommendations else { return nil }
        return reconciledRows(recommendations: recommendations, shortcuts: shortcuts ?? [], config: homeRowsConfig)
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "nav_home"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { editButton }
                if !isEditing {
                    ToolbarItem(placement: .primaryAction) { settingsButton }
                }
            }
            .task(id: reloadTrigger) { await load() }
            .task {
                // This screen loads once and then stays put, which is what makes returning to
                // it cheap. That was fine while the shell tore the whole tab view down on every
                // Settings visit — the reload came for free on the way back. Settings is now
                // presented *over* the app and this view outlives it, so the one case that used
                // to be covered by accident needs handling: a first load that ran (and failed)
                // before there was a server to talk to. Retry when a connection actually
                // arrives; a load that already succeeded is left alone.
                guard sessionSubscription == nil else { return }
                // Seeded before subscribing: `observeReadiness` replays the current value, and
                // without this that replay looks like an arrival and restarts a load that is
                // already in flight.
                wasReady = KmpHelper.shared.readyForCommands
                sessionSubscription = KmpHelper.shared.observeReadiness { isReady in
                    // Kotlin's `Boolean` crosses as `KotlinBoolean` for a lambda parameter.
                    let ready = isReady.boolValue
                    // Only the not-ready → ready edge. Reacting to every emission meant each one
                    // bumped `reloadTrigger`, and since `.task(id:)` cancels the running task on
                    // a new id, a burst of them could keep cancelling the load that was about to
                    // populate the screen.
                    let justBecameReady = ready && !wasReady
                    wasReady = ready
                    guard justBecameReady, loadFailed || recommendations == nil else { return }
                    reloadTrigger = UUID()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            editingList
        } else if let rows {
            let visible = rows.filter(\.enabled).map(\.row)
            if visible.isEmpty {
                refreshable(ContentUnavailableView(String(localized: "library_empty"), systemImage: "house"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(visible) { row in
                            carouselRow(row)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .refreshable { await load() }
            }
        } else if loadFailed {
            refreshable(ContentUnavailableView(String(localized: "library_error"), systemImage: "wifi.exclamationmark"))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Makes a "nothing to show" state pull-to-refreshable. `.refreshable` only responds inside
    /// a scrollable, and a bare `ContentUnavailableView` isn't one — so the empty and failed
    /// states offered no way back other than leaving the tab and returning. The container frame
    /// keeps the message centred and gives the gesture something to pull against even though
    /// the content is shorter than the screen.
    private func refreshable(_ view: some View) -> some View {
        ScrollView {
            view.containerRelativeFrame([.horizontal, .vertical])
        }
        .refreshable { await load() }
    }

    private func carouselRow(_ row: HomeRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        HomeCarouselTile(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            // The lift a long press starts scales the tile up *in place*, before the preview is
            // handed to the context menu's own window — and this scroll view's bounds are exactly
            // the tile's height, so that growth used to be sliced off flat along the top edge,
            // right under the row title. It read as the title cutting into the artwork. Nothing
            // here overflows in normal use (the content is the tiles' own height, and the scroll
            // view is full-width, so there are no side edges to spill past); the clip was only
            // ever catching that one animation.
            .scrollClipDisabled()
        }
    }

    // MARK: - Toolbar

    private var editButton: some View {
        Button {
            if isEditing {
                commitEdits()
            } else {
                beginEditing()
            }
        } label: {
            Image(systemName: isEditing ? "checkmark" : "pencil")
        }
        .accessibilityLabel(String(localized: isEditing ? "home_save_rows" : "home_edit_rows"))
        .disabled(rows == nil)
    }

    private var settingsButton: some View {
        Button {
            KmpHelper.shared.requestSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel(String(localized: "nav_settings"))
    }

    // MARK: - Edit mode

    /// Snapshots the currently-reconciled rows into two working-copy arrays — isolated from a
    /// fresh fetch until Done commits them, same as the Compose original's `items` snapshot.
    private func beginEditing() {
        guard let rows else { return }
        editingEnabledRows = rows.filter(\.enabled).map(\.row)
        editingDisabledRows = rows.filter { !$0.enabled }.map(\.row)
        isEditing = true
    }

    private func commitEdits() {
        let config =
            editingEnabledRows.map { SettingsRepository.HomeRowPref(id: $0.id, enabled: true) } +
            editingDisabledRows.map { SettingsRepository.HomeRowPref(id: $0.id, enabled: false) }
        KmpHelper.shared.setHomeRowsConfig(config: config)
        homeRowsConfig = config
        isEditing = false
    }

    /// Two `List` sections instead of Compose's single index-clamped-drag `LazyColumn` — reorder
    /// (`.onMove`) only applies within Enabled; moving a row to/from Disabled is just toggling
    /// its switch, which is enough to reproduce `moveToEnabledBoundary`'s end result (enabled
    /// rows contiguous, in the order the user left them) without replicating its drag-index
    /// clamping or the Compose original's tap-swallow-but-allow-drag gesture scrim, neither of
    /// which has a direct SwiftUI equivalent.
    private var editingList: some View {
        List {
            Section {
                ForEach(editingEnabledRows) { row in
                    editingRow(row, enabled: true)
                }
                .onMove { editingEnabledRows.move(fromOffsets: $0, toOffset: $1) }
            }
            if !editingDisabledRows.isEmpty {
                Section {
                    ForEach(editingDisabledRows) { row in
                        editingRow(row, enabled: false)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private func editingRow(_ row: HomeRow, enabled: Bool) -> some View {
        HStack {
            Text(row.title)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { enabled },
                    set: { newValue in toggleEnabled(row, newValue: newValue) }
                )
            )
            .labelsHidden()
            // Can't disable the only remaining enabled row, matching the Compose original.
            .disabled(enabled && editingEnabledRows.count <= 1)
        }
    }

    private func toggleEnabled(_ row: HomeRow, newValue: Bool) {
        if newValue {
            editingDisabledRows.removeAll { $0.id == row.id }
            editingEnabledRows.append(row)
        } else {
            editingEnabledRows.removeAll { $0.id == row.id }
            editingDisabledRows.insert(row, at: 0)
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        // Deliberately does *not* clear `recommendations` first. Doing so dropped the whole
        // screen back to the spinner for the length of a pull-to-refresh, so the carousels
        // vanished and reappeared — where the point of the gesture is that you keep looking at
        // what you have until better data arrives. The first load needs no help from it either:
        // `recommendations` already starts nil, which is what shows the spinner.
        loadFailed = false
        homeRowsConfig = KmpHelper.shared.homeRowsConfig()

        async let recommendationsResult: [RecommendationFolder]? = withCheckedContinuation { continuation in
            KmpHelper.shared.fetchRecommendationFolders { continuation.resume(returning: $0) }
        }
        async let shortcutsResult: [AppMediaItem]? = withCheckedContinuation { continuation in
            KmpHelper.shared.fetchShortcuts { continuation.resume(returning: $0) }
        }
        let (loadedRecommendations, loadedShortcuts) = await (recommendationsResult, shortcutsResult)
        guard !Task.isCancelled else { return }
        // Nil means the round trip exceeded KmpHelper's timeout. An RPC *failure* does not
        // arrive that way: `launchFetch` reduces it with `getOrNull() ?: emptyList()`, so a
        // server that refused and a server with nothing to recommend both hand back an empty
        // list. `readyForCommands` is what separates them.
        //
        // This is why Home stayed blank after a fresh install: `sendRequest` gates on
        // `ensureReadyForCommands`, which gives up after 10s — inside the 30s fetch timeout — so
        // the first load returned [] rather than nil, `loadFailed` stayed false, and the retry
        // below never fired once credentials were finally entered.
        let unreachable = loadedRecommendations?.isEmpty != false && !KmpHelper.shared.readyForCommands
        guard let loadedRecommendations, !unreachable else {
            // Leaves whatever is on screen in place. With content already showing, `content`
            // takes the `rows` branch and this flag never reaches the error view — a failed
            // refresh keeps the stale carousels rather than throwing them away, and the RPC
            // error has already surfaced as a toast via `ErrorMessageBus`. The flag still
            // matters for the empty case, and for the reconnect retry in `body`.
            loadFailed = true
            return
        }
        recommendations = loadedRecommendations
        shortcuts = loadedShortcuts ?? []
    }
}

/// A titled carousel's row data — mirrors Compose's `ItemCategory`, narrowed to what Home
/// actually needs (no `list`/`filter`, which Home never sets).
struct HomeRow: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [MediaItem]

    /// Includes `items` deliberately: a carousel keeps its row id across refreshes, so an
    /// id-only `==` told SwiftUI a row whose contents had just changed was unchanged, and the
    /// carousel kept rendering the old items (same defect as `MediaItem`'s own `==`).
    static func == (lhs: HomeRow, rhs: HomeRow) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.items == rhs.items
    }
}

private let shortcutsRowId = "shortcuts"

/// Builds and reconciles rows exactly like `HomeScreen.kt`'s `getCategories`/`HomeRowsConfig.kt`'s
/// `reconcileHomeRows` — ported 1:1 since both are small, pure, dependency-free functions.
private func reconciledRows(
    recommendations: [RecommendationFolder],
    shortcuts: [AppMediaItem],
    config: [SettingsRepository.HomeRowPref]
) -> [(row: HomeRow, enabled: Bool)] {
    var seenKeys = Set<String>()
    let recommendationRows = recommendations.compactMap { folder -> HomeRow? in
        let items = folder.items ?? []
        guard items.contains(where: { !($0 is RecommendationFolder) }) else { return nil }
        guard seenKeys.insert(folder.itemId).inserted else { return nil }
        // `displayName` is the server's English name for a curated row; `translationKey` is how
        // it says which row this is. See `RecommendationRowTitle`.
        let title = RecommendationRowTitle.localized(
            translationKey: folder.translationKey,
            serverName: folder.displayName
        )
        return HomeRow(id: folder.itemId, title: title, items: items.map(MediaItem.init))
    }

    let baseRows: [HomeRow]
    if !shortcuts.isEmpty {
        let shortcutsRow = HomeRow(
            id: shortcutsRowId,
            title: String(localized: "home_shortcuts"),
            items: shortcuts.map(MediaItem.init)
        )
        baseRows = recommendationRows + [shortcutsRow]
    } else {
        baseRows = recommendationRows
    }

    let enabledById = Dictionary(config.map { ($0.id, $0.enabled) }, uniquingKeysWith: { first, _ in first })
    let orderById = Dictionary(config.enumerated().map { (offset, pref) in (pref.id, offset) }, uniquingKeysWith: { first, _ in first })

    let sorted = baseRows
        .map { row in (row: row, enabled: enabledById[row.id] ?? true) }
        .sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            return (orderById[lhs.row.id] ?? Int.max) < (orderById[rhs.row.id] ?? Int.max)
        }

    // Pin shortcuts to the top only the first time it appears (no config entry for it yet) —
    // once the user has any saved position for it, respect that instead.
    if config.contains(where: { $0.id == shortcutsRowId }) {
        return sorted
    }
    return sorted.filter { $0.row.id == shortcutsRowId } + sorted.filter { $0.row.id != shortcutsRowId }
}

/// A carousel tile — same visual shape as `LibraryListView`'s grid tile, sized for a horizontal
/// `LazyHStack` rather than a `LazyVGrid` (fixed width instead of `.flexible` filling the grid
/// column). Same browsable-vs-play tap dispatch as everywhere else.
/// Says whether a tile is music, a podcast or an audiobook, since the artwork alone doesn't.
///
/// Deliberately not a material: material takes its brightness from what is behind it, and behind
/// this is arbitrary album art, so a white glyph would vanish over anything pale. A fixed dark
/// scrim with a white glyph is the one combination legible over every cover — which is why Music
/// and Photos badge over artwork the same way, in both light and dark mode.
private struct ContentTypeBadge: View {

    let badge: MediaItem.Kind.ContentBadge

    init(_ badge: MediaItem.Kind.ContentBadge) { self.badge = badge }

    var body: some View {
        Image(systemName: badge.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.55), in: .circle)
            // Hairline rather than a stroke: over a dark cover the scrim and the artwork are
            // near the same value and the disc loses its edge. `strokeBorder` insets, so the
            // line stays inside the circle instead of straddling it and reading as thicker.
            .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
            .accessibilityLabel(badge.label)
    }
}

private struct HomeCarouselTile: View {

    let item: MediaItem
    private let width: CGFloat = 140

    var body: some View {
        Group {
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
                Button {
                    _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, endlessMix: false)
                } label: {
                    tile
                }
                .buttonStyle(.plain)
            }
        }
        // Same reference size the tile decodes at, so the preview is a cache hit — see
        // `itemContextMenu`'s doc on why tiles preview the artwork alone.
        .itemContextMenu(item: item, artworkPreviewSize: width)
    }

    private var tile: some View {
        VStack(alignment: item.kind.prefersCircularArtwork ? .center : .leading, spacing: 8) {
            ArtworkView(
                url: item.artworkURL,
                kind: item.kind,
                sizing: .flexible(decodeHint: width),
                showsBorder: true
            )
                .overlay(alignment: .bottomTrailing) {
                    if let badge = item.kind.contentBadge {
                        // No circular-artwork case to inset for: artist is the only kind with
                        // circular artwork, and it carries no badge.
                        ContentTypeBadge(badge).padding(6)
                    }
                }
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
        .frame(width: width, alignment: item.kind.prefersCircularArtwork ? .center : .leading)
        .contentShape(.rect)
    }
}
