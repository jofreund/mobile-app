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

/// Which bottom tab is selected. `.settingsTrigger` is never actually shown — see `body`'s
/// `.onChange(of:)`, which reverts it immediately and asks `AppShellRootView` (via
/// `KmpHelper.requestSettings()`) to swap the whole screen instead, matching Settings' existing
/// behavior of replacing the tab shell entirely rather than being a peer tab with its own content.
enum AppTab: Hashable {
    case home, library, search, settingsTrigger
}

/// Replaces `MainTabHostView` (Phase E1/E2's single shared `NavigationStack` over one Compose
/// tree hosting all four tabs). That worked while every native push was a genuine drill-down
/// *from inside* an already-showing screen; Search doesn't fit that shape — it's a tab root, and
/// pushing it the same way would cover the tab bar along with everything else. This is Swift's
/// first native `TabView`: each tab owns its own `NavigationStack` and (for Home/Library) its
/// own Compose host — see `ComposeScreenHosts.kt`'s doc for the full picture, including why the
/// floating player bar needed splitting into a collapsed/expanded pair rather than becoming a
/// fifth per-tab host.
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
            Tab("nav_settings", systemImage: "gearshape", value: .settingsTrigger) { Color.clear }
        }
        .safeAreaInset(edge: .bottom) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.FloatingBarCollapsedController(
                    onExpand: { playerExpanded = true },
                    onNavigateToItemDetails: pushItemDetailsOnActiveTab
                )
            })
            .frame(height: 100)
        }
        .fullScreenCover(isPresented: $playerExpanded) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.FloatingBarExpandedController(
                    onCollapse: { playerExpanded = false },
                    onNavigateToItemDetails: pushItemDetailsOnActiveTab
                )
            })
            .ignoresSafeArea()
        }
        .onChange(of: selectedTab) { old, new in
            guard new == .settingsTrigger else { return }
            selectedTab = old
            KmpHelper.shared.requestSettings()
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
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ItemDetailsRoute.self) { route in
                ItemDetailsView(route: route)
            }
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

    private var searchTab: some View {
        NavigationStack(path: $searchPath) {
            SearchView()
                .navigationDestination(for: ItemDetailsRoute.self) { route in
                    ItemDetailsView(route: route)
                }
        }
    }

    /// The floating bar's own "tap a queue item" navigation has no tab of its own — push
    /// onto whichever tab the user is actually looking at, so backing out returns to it and
    /// switching tabs away/back preserves the pushed detail. Home/Library push directly;
    /// Search pushes onto its own stack too. `.settingsTrigger` never has meaningful content
    /// to push onto, so it's a no-op there (unreachable in practice — the floating bar isn't
    /// visible while Settings is open).
    private func pushItemDetailsOnActiveTab(itemId: String, mediaType: MediaType, providerId: String) {
        let route = ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId)
        switch selectedTab {
        case .home: homePath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        case .settingsTrigger: break
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
