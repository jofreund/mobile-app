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

/// Which bottom tab is selected. Settings isn't one of these — it's reached via a settings
/// icon in Home's own toolbar (`HomeScreen.kt`'s `LandingPageTopBar`), which calls
/// `KmpHelper.requestSettings()` directly; `AppShellRootView` swaps the whole screen away when
/// that fires, same as it always has, so Settings was never a good fit for a peer tab with its
/// own content in the first place.
enum AppTab: Hashable {
    case home, library, search
}

/// Replaces `MainTabHostView` (Phase E1/E2's single shared `NavigationStack` over one Compose
/// tree hosting all four tabs). That worked while every native push was a genuine drill-down
/// *from inside* an already-showing screen; Search doesn't fit that shape — it's a tab root, and
/// pushing it the same way would cover the tab bar along with everything else. This is Swift's
/// first native `TabView`: each tab owns its own `NavigationStack` and (for Home/Library) its
/// own Compose host — see `ComposeScreenHosts.kt`'s doc for the full picture.
///
/// The collapsed floating player bar is mounted once **per tab** (`.safeAreaInset(edge: .bottom)`
/// inside each of `homeTab`/`libraryTab`/`searchTab`), not once at the `TabView` level. Two things
/// were tried and rejected first, both on-device: `.safeAreaInset` applied directly to the
/// `TabView` hides the native tab bar entirely (confirmed empirically — not documented anywhere,
/// just reproducible); `.tabViewBottomAccessory` (the API that looks purpose-built for exactly
/// this — Apple Music's mini-player-above-the-tab-bar) keeps the tab bar visible but never
/// renders the hosted Compose content inside it, on this iOS 26 beta — sizing fixes
/// (`.frame`, a `sizeThatFits` override on `ComposeHostView`) didn't change that, so it's most
/// likely a compositing issue with Metal-backed content in that specific container, not a layout
/// bug we can fix from here. Per-tab mounting means `FloatingBarCollapsedController` runs three
/// times over — its `ErrorMessageBus` collection (a single-consumer `Channel`) now has three
/// collectors competing for each buffered item, so an error toast surfaces on whichever tab's
/// instance happens to receive it, not necessarily the one on screen. Accepted: correct delivery
/// everywhere would need a redesign (e.g. one dedicated always-mounted, always-visible-through
/// overlay just for toasts), which is more machinery than this gap warrants right now.
///
/// `ItemDetailsView` (ItemDetails/ItemDetailsView.swift) routes to a native screen for every
/// item type this app pushes: Album/Playlist/Podcast/Audiobook share `ContainerItemDetailsView`,
/// Artist and Genre get their own screens. `LibraryListView`/`BrowseView` are the Phase E2 Library
/// destinations; `SearchView` (Search/SearchView.swift) is Phase E3, fully native from the start
/// since it never had a Compose predecessor to drill down from within this shell.
struct AppTabView: View {

    @State private var selectedTab: AppTab = .home

    // Each tab keeps its own stack — a real improvement over the old single shared
    // NavigationPath, where every tab's pushes piled onto one stack regardless of which
    // tab was active. ItemDetailsRoute is reachable from all three real tabs (Home rows,
    // Library items, Search results); LibraryCategoryRoute/BrowseRoute only from Library.
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    @State private var playerExpanded = false
    @State private var deepLinkSubscription: Cancellable?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("nav_home", systemImage: "house", value: .home) { homeTab }
            Tab("nav_library", systemImage: "square.stack", value: .library) { libraryTab }
            Tab("nav_search", systemImage: "magnifyingglass", value: .search) { searchTab }
        }
        .fullScreenCover(isPresented: $playerExpanded) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.FloatingBarExpandedController(
                    onCollapse: { playerExpanded = false },
                    onNavigateToItemDetails: { itemId, mediaType, providerId in
                        // The expanded player is one shared, modally-presented instance
                        // (not per-tab like the collapsed bar), so a queue-item tap here
                        // pushes onto whichever tab is actually behind it.
                        playerExpanded = false
                        let route = ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId)
                        switch selectedTab {
                        case .home: homePath.append(route)
                        case .library: libraryPath.append(route)
                        case .search: searchPath.append(route)
                        }
                    }
                )
            })
            .ignoresSafeArea()
        }
        .task {
            guard deepLinkSubscription == nil else { return }
            deepLinkSubscription = KmpHelper.shared.deepLinks.subscribe { [self] dest in
                // .players isn't handled here — FloatingBarCollapsedController's own
                // Kotlin-side LaunchedEffect owns that case, since only Compose can flip
                // the floating bar's local expand state. Both sides read the same
                // retained value safely; each only consumes the cases it owns.
                guard let dest else { return }
                if dest is DeepLinkDestinationHome {
                    selectedTab = .home
                    KmpHelper.shared.consumeDeepLink(destination: dest)
                } else if let library = dest as? DeepLinkDestinationLibrary {
                    selectedTab = .library
                    if let mediaType = library.mediaType {
                        libraryPath.append(LibraryCategoryRoute(mediaType: mediaType))
                    }
                    KmpHelper.shared.consumeDeepLink(destination: dest)
                } else if dest is DeepLinkDestinationSearch {
                    selectedTab = .search
                    KmpHelper.shared.consumeDeepLink(destination: dest)
                }
            }
        }
    }

    private var homeTab: some View {
        NavigationStack(path: $homePath) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.HomeAppController(onNavigateToItemDetails: { itemId, mediaType, providerId in
                    homePath.append(ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId))
                })
            })
            // Compose draws its own screen headers and expects to own the full screen
            // under the status bar. `ignoresSafeArea` applied outside a NavigationStack
            // does not flow through to its root content — the space NavigationStack
            // reserves for its (hidden) bar is a layout concern of what's *inside* it.
            // Only the top edge — the bottom safe area here is what the enclosing
            // TabView's tab bar contributes; ignoring it too made the tab bar disappear
            // (the Compose host's UIKit view claimed that space instead of ceding it).
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ItemDetailsRoute.self) { route in
                ItemDetailsView(route: route)
            }
        }
        .floatingPlayerBar(playerExpanded: $playerExpanded) { itemId, mediaType, providerId in
            homePath.append(ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId))
        }
    }

    private var libraryTab: some View {
        NavigationStack(path: $libraryPath) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.LibraryAppController(
                    onNavigateToLibraryCategory: { mediaType in
                        libraryPath.append(LibraryCategoryRoute(mediaType: mediaType))
                    },
                    onNavigateToBrowse: {
                        libraryPath.append(BrowseRoute(path: nil, title: nil))
                    }
                )
            })
            .ignoresSafeArea(edges: .top)
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
        .floatingPlayerBar(playerExpanded: $playerExpanded) { itemId, mediaType, providerId in
            libraryPath.append(ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId))
        }
    }

    private var searchTab: some View {
        NavigationStack(path: $searchPath) {
            SearchView()
                .navigationDestination(for: ItemDetailsRoute.self) { route in
                    ItemDetailsView(route: route)
                }
        }
        .floatingPlayerBar(playerExpanded: $playerExpanded) { itemId, mediaType, providerId in
            searchPath.append(ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId))
        }
    }
}

private extension View {
    /// Reserves space for, and hosts, this tab's own instance of the collapsed floating
    /// player bar — see `AppTabView`'s doc for why this is per-tab rather than shared.
    func floatingPlayerBar(
        playerExpanded: Binding<Bool>,
        onNavigateToItemDetails: @escaping (String, MediaType, String) -> Void
    ) -> some View {
        safeAreaInset(edge: .bottom) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.FloatingBarCollapsedController(
                    onExpand: { playerExpanded.wrappedValue = true },
                    onNavigateToItemDetails: onNavigateToItemDetails
                )
            })
            .frame(height: 100)
        }
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
