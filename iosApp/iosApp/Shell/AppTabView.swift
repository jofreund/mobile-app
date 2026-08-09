import SwiftUI
import UIKit
import ComposeApp

/// Wraps a Kotlin `UIViewController` factory for SwiftUI. Down to a single user —
/// `FloatingBarSideEffectsController` below — now that every visible screen is native;
/// lived in `AppShellRootView.swift` while the Main/Settings switch still hosted Compose.
private struct ComposeHostView: UIViewControllerRepresentable {
    let makeController: () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController { makeController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

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
/// The collapsed player bar rides in `.tabViewBottomAccessory` — the iOS 26 API built for
/// precisely this, Apple Music's mini-player-above-the-tab-bar — so the system owns where it
/// sits and, critically, how much room scroll views leave for it.
///
/// It didn't start there. The bar was hand-mounted per tab via `.safeAreaInset(edge: .bottom)`
/// because two alternatives had been tried and rejected on-device: `.safeAreaInset` applied to
/// the `TabView` itself hides the native tab bar outright (reproducible, undocumented), and
/// `.tabViewBottomAccessory` kept the tab bar but never rendered the bar's content — which at
/// the time was a hosted **Compose** `UIViewController`, so the failure was almost certainly
/// Metal-backed content in that container rather than the API. The bar is plain SwiftUI now
/// (`MiniPlayerView.swift`), which retires that objection.
///
/// The hand-rolled version was worth abandoning on its own merits: its reservation never
/// reached the scroll views, so the last row of Home/Library/Search could not be scrolled clear
/// of the bar no matter what — two attempts to fix that by adjusting the reservation
/// (`152bd790`, `e95e8d62`) both missed, because the problem was never the number.
///
/// Moving it up also let `FloatingBarSideEffectsController` collapse from three mounts to one.
/// It collects `ErrorMessageBus`, a single-consumer `Channel`, so three instances meant three
/// collectors racing for every message and toasts appearing on whichever tab happened to win —
/// a documented, accepted gap that this change closes for free.
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
    @State private var playerBarStore = PlayerBarStore()
    @State private var isSearchFieldActive = false
    /// The mini player's paging position, held here rather than inside `MiniPlayerView` — the
    /// accessory's content is rebuilt as tabs change, and state inside it went back to nil each
    /// time, snapping the pager to the first player before animating to the selected one.
    @State private var miniPlayerScrollID: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("nav_home", systemImage: "house", value: .home) { homeTab }
            Tab("nav_library", systemImage: "square.stack", value: .library) { libraryTab }
            Tab("nav_search", systemImage: "magnifyingglass", value: .search) { searchTab }
        }
        // Minimising the tab bar on scroll is what buys the accessory its `.expanded` height —
        // there is no way to ask for a taller accessory directly (the API is content + isEnabled
        // and nothing else). MiniPlayerRow reads the placement and spends the extra room.
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            // Hidden only while Search's field has focus, or it renders squeezed against the
            // keyboard — the one behaviour worth keeping from the hand-rolled version.
            if !(selectedTab == .search && isSearchFieldActive) {
                MiniPlayerView(store: playerBarStore, scrollID: $miniPlayerScrollID) {
                    playerExpanded = true
                }
            }
        }
        // Mounted once here rather than once per tab, which it had to be while it rode along
        // with the mini player. `FloatingBarSideEffectsController` collects `ErrorMessageBus`,
        // a single-consumer Channel, so three instances meant three collectors racing for each
        // message and toasts surfacing on whichever tab won — a documented, accepted gap that
        // just closed itself. Still `.background` and non-hit-testable: `AppShellChrome` fills
        // its host with an opaque colour, so in front it would cover whatever it overlaps.
        .background(alignment: .bottom) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.FloatingBarSideEffectsController(
                    onExpand: { playerExpanded = true }
                )
            })
            .frame(height: MiniPlayerView.sideEffectsHostHeight)
            .allowsHitTesting(false)
        }
        .fullScreenCover(isPresented: $playerExpanded) {
            ExpandedPlayerView(store: playerBarStore) { playerExpanded = false }
        }
        .task { playerBarStore.start() }
        .task {
            guard deepLinkSubscription == nil else { return }
            deepLinkSubscription = KmpHelper.shared.deepLinks.subscribe { [self] dest in
                // .players isn't handled here — FloatingBarSideEffectsController's own
                // Kotlin-side LaunchedEffect owns that case, flipping `playerExpanded`
                // through the `onExpand` closure it's constructed with below. Both sides
                // read the same retained value safely; each only consumes the cases it owns.
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
            HomeView()
                .navigationDestination(for: ItemDetailsRoute.self) { route in
                    ItemDetailsView(route: route)
                }
        }
    }

    private var libraryTab: some View {
        NavigationStack(path: $libraryPath) {
            LibraryView(
                onNavigateToLibraryCategory: { mediaType in
                    libraryPath.append(LibraryCategoryRoute(mediaType: mediaType))
                },
                onNavigateToBrowse: {
                    libraryPath.append(BrowseRoute(path: nil, title: nil))
                }
            )
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
            SearchView(isSearchFieldActive: $isSearchFieldActive)
                .navigationDestination(for: ItemDetailsRoute.self) { route in
                    ItemDetailsView(route: route)
                }
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
