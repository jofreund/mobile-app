import SwiftUI
import ComposeApp

/// Where a tap on any browsable/playable item — from a Home row, Library,
/// Browse, Search, or the floating player bar's queue — asks to go. Carries
/// exactly what `ItemDetailsViewModel`'s Koin `parametersOf` needs on the
/// Compose side, so a future real detail view can resolve the same way.
struct ItemDetailsRoute: Hashable {
    let itemId: String
    let mediaType: MediaType
    let providerId: String

    // Hand-written rather than synthesized: MediaType is a Kotlin-bridged
    // KotlinEnum, and Swift can't derive Hashable through a member type it
    // didn't declare. Hashing on `.name` (Kotlin's plain-String enum name)
    // sidesteps needing MediaType itself to be Hashable.
    static func == (lhs: ItemDetailsRoute, rhs: ItemDetailsRoute) -> Bool {
        lhs.itemId == rhs.itemId && lhs.providerId == rhs.providerId && lhs.mediaType == rhs.mediaType
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(itemId)
        hasher.combine(providerId)
        hasher.combine(mediaType.name)
    }
}

/// Wraps `MainAppController()` in a real `NavigationStack` — the first
/// destinations Swift owns instead of Compose's own `MultiBackStack`. See
/// `ComposeScreenHosts.kt`'s doc for the full picture: everything *except*
/// ItemDetails and the Library tab's own category grid/Browse tree (tabs,
/// ItemList's search/sort/filter, the floating player bar) still lives
/// inside the one Compose tree `MainAppController()` hosts; a tap that used
/// to push `MainNav.ItemDetails`, `MainNav.LibraryList`, or `MainNav.Browse`
/// surfaces here instead.
///
/// `ItemDetailsView` (ItemDetails/ItemDetailsView.swift) routes to a native screen for
/// every item type this app pushes: Album/Playlist/Podcast/Audiobook share
/// `ContainerItemDetailsView`, Artist and Genre get their own screens
/// (`ArtistDetailsView.swift`, `GenreDetailsView.swift`). `ItemDetailsPlaceholderView`
/// below is now dead code for every reachable `MediaType` but stays as the fallback for
/// whatever isn't. `LibraryListView` and `BrowseView` (Library/LibraryListView.swift,
/// Library/BrowseView.swift) are the Phase E2 counterparts: one unfiltered grid per
/// category, and the folder-style provider browse tree, both reached from the Library
/// tab's own category tiles. `BrowseView` pushes further `BrowseRoute`s for its own
/// recursive "drill into a folder" navigation — one `.navigationDestination` registration
/// here resolves pushes of that type at any depth, not just the first level.
struct MainTabHostView: View {

    // NavigationPath (type-erased), not a typed array: this stack carries three
    // distinct route types (ItemDetailsRoute, LibraryCategoryRoute, BrowseRoute) and
    // will grow more as further Library-tab pieces move to Swift.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ComposeHostView(makeController: makeMainController)
                // Compose draws its own screen headers ("Home", tab titles, …)
                // and expects to own the full screen under the status bar, same
                // as before this NavigationStack existed. `ignoresSafeArea`
                // applied outside a NavigationStack does not flow through to
                // its root content — the space NavigationStack reserves for
                // its (hidden) bar is a layout concern of what's *inside* it,
                // so it has to be reclaimed here, not at AppShellRootView's
                // level. Only the pushed native destination below should get
                // real navigation chrome.
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ItemDetailsRoute.self) { route in
                    ItemDetailsView(route: route)
                }
                .navigationDestination(for: LibraryCategoryRoute.self) { route in
                    LibraryListView(route: route)
                }
                .navigationDestination(for: BrowseRoute.self) { route in
                    BrowseView(route: route)
                }
        }
    }

    private func makeMainController() -> UIViewController {
        ComposeScreenHostsKt.MainAppController(
            onNavigateToItemDetails: { [self] itemId, mediaType, providerId in
                path.append(ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId))
            },
            onNavigateToLibraryCategory: { [self] mediaType in
                path.append(LibraryCategoryRoute(mediaType: mediaType))
            },
            onNavigateToBrowse: { [self] in
                path.append(BrowseRoute(path: nil, title: nil))
            }
        )
    }
}

/// Generic fallback, kept for whatever `MediaType` case isn't one `ItemDetailsView`
/// routes explicitly — currently none of the ones this app can actually push, since
/// Artist and Genre gained real screens too.
struct ItemDetailsPlaceholderView: View {

    let route: ItemDetailsRoute

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Item Details")
                .font(.title2.weight(.semibold))
            Text(route.mediaType.name.capitalized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(route.itemId)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}
