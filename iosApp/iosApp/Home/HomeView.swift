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

    @State private var homeRowsConfig: [SettingsRepository.HomeRowPref] = []
    @State private var isEditing = false
    @State private var editingEnabledRows: [HomeRow] = []
    @State private var editingDisabledRows: [HomeRow] = []

    /// Rows the server + shortcuts resolved to, reconciled against persisted enabled/order
    /// prefs — recomputed whenever the fetch or the persisted config changes. `nil` while
    /// loading/on failure.
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
                sessionSubscription = KmpHelper.shared.sessionState.subscribe { state in
                    guard loadFailed || recommendations == nil else { return }
                    let connected = state as? SessionState.Connected
                    guard connected?.dataConnectionState is DataConnectionStateAuthenticated else { return }
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
        recommendations = nil
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
        guard let loadedRecommendations else {
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
        return HomeRow(id: folder.itemId, title: folder.displayName, items: items.map(MediaItem.init))
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
                    _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, radio: false)
                } label: {
                    tile
                }
                .buttonStyle(.plain)
            }
        }
        .itemContextMenu(item: item)
    }

    private var tile: some View {
        VStack(alignment: item.kind.prefersCircularArtwork ? .center : .leading, spacing: 8) {
            ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .flexible(decodeHint: width))
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
