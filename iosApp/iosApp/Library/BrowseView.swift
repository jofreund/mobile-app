import SwiftUI
import MusicAssistantKit

/// One level of the server's `music/browse` provider tree — mirrors `MainNav.Browse`'s shape.
/// `path: nil` is the root level; a folder's own `path` (falling back to its `uri`) becomes
/// the next level's route, exactly as `MainNav.Browse(path = item.path ?: item.uri, …)` does
/// on the Compose side.
struct BrowseRoute: Hashable {
    let path: String?
    let title: String?
}

/// The native counterpart to `BrowseScreen.kt`/`BrowseViewModel.kt`: a folder-style browser
/// with no pagination, sort, or favorites — the server returns a whole level in one shot.
/// Folders push another `BrowseView` for the next level. The server's own ".." entry
/// (`RecommendationFolder.isParentLink`) is filtered out entirely — on Compose it existed to
/// map onto that side's own back navigation, which a native NavigationStack already gives
/// users for free via the interactive pop gesture and back button. Browsable items
/// (Artist/Album/Playlist/Podcast/Audiobook/Genre) push `ItemDetailsRoute`; anything else
/// (Track, RadioStation, …) dispatches "play now", same simplification as `LibraryGridTile`
/// — the long-press-driven default-click-action setting isn't ported here.
struct BrowseView: View {

    let route: BrowseRoute

    @State private var items: [MediaItem]?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView(
                        String(localized: "library_empty"),
                        systemImage: "tray"
                    )
                } else {
                    List(items) { item in
                        BrowseRow(item: item)
                    }
                    .listStyle(.plain)
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
        .navigationTitle(route.title ?? String(localized: "nav_browse"))
        .navigationBarTitleDisplayMode(.large)
        .task(id: route) { await load() }
    }

    @MainActor
    private func load() async {
        // Same reasoning as LibraryListView: don't clear what's on screen before refetching, or
        // a reload flashes an empty screen. Nothing to clear on the first load anyway.
        loadFailed = false

        let result: [AppMediaItem]? = await withCheckedContinuation { continuation in
            KmpHelper.shared.fetchBrowseItems(path: route.path) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            loadFailed = true
            return
        }
        // The server's own ".." entry is redundant with the interactive pop gesture / back
        // button a native NavigationStack already gives users for free.
        items = result.asMediaItems.filter {
            !(($0.kotlin as? RecommendationFolder)?.isParentLink ?? false)
        }
    }
}

private struct BrowseRow: View {

    let item: MediaItem

    /// Only ever true for the playable branch; the navigating ones bring their own highlight.
    @State private var isPressed = false

    var body: some View {
        Group {
            if let folder = item.kotlin as? RecommendationFolder {
                NavigationLink(
                    value: BrowseRoute(path: folder.path ?? folder.uri, title: folder.displayName)
                ) { row }
            } else if item.kind.isBrowsable {
                NavigationLink(
                    value: ItemDetailsRoute(
                        itemId: item.kotlin.itemId,
                        mediaType: item.kotlin.mediaType,
                        providerId: item.kotlin.provider
                    )
                ) { row }
            } else {
                Button { _ = KmpHelper.shared.playOnSelectedPlayer(item: item.kotlin, option: .replace, endlessMix: false) } label: {
                    row
                }
                // Wins over the `.plain` below, which stays for the navigating branches — those
                // already get the system's own row highlight.
                .buttonStyle(PressReportingButtonStyle { isPressed = $0 })
            }
        }
        .buttonStyle(.plain)
        .pressHighlight(isPressed)
    }

    private var row: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.artworkURL, kind: item.kind, sizing: .fixed(48))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // No chevron drawn here. A `NavigationLink` in a `List` already gets the system
            // disclosure indicator, and the two branches above that pushed one are exactly the
            // two this used to draw for — so it rendered a second chevron beside the real one.
            // The play-on-tap branch is a `Button` and correctly shows none.
        }
        .contentShape(.rect)
    }
}
