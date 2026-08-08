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
/// The collapsed floating player bar is mounted once **per tab** (`.safeAreaInset(edge: .bottom)`
/// inside each of `homeTab`/`libraryTab`/`searchTab`), not once at the `TabView` level. Two things
/// were tried and rejected first, both on-device: `.safeAreaInset` applied directly to the
/// `TabView` hides the native tab bar entirely (confirmed empirically — not documented anywhere,
/// just reproducible); `.tabViewBottomAccessory` (the API that looks purpose-built for exactly
/// this — Apple Music's mini-player-above-the-tab-bar) keeps the tab bar visible but never
/// renders the hosted Compose content inside it, on this iOS 26 beta — sizing fixes
/// (`.frame`, a `sizeThatFits` override on `ComposeHostView`) didn't change that, so it's most
/// likely a compositing issue with Metal-backed content in that specific container, not a layout
/// bug we can fix from here. Per-tab mounting means `FloatingBarSideEffectsController` runs three
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
    @State private var playerBarStore = PlayerBarStore()
    @State private var isSearchFieldActive = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("nav_home", systemImage: "house", value: .home) { homeTab }
            Tab("nav_library", systemImage: "square.stack", value: .library) { libraryTab }
            Tab("nav_search", systemImage: "magnifyingglass", value: .search) { searchTab }
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
        .floatingPlayerBar(store: playerBarStore, playerExpanded: $playerExpanded)
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
        .floatingPlayerBar(store: playerBarStore, playerExpanded: $playerExpanded)
    }

    private var searchTab: some View {
        NavigationStack(path: $searchPath) {
            SearchView(isSearchFieldActive: $isSearchFieldActive)
                .navigationDestination(for: ItemDetailsRoute.self) { route in
                    ItemDetailsView(route: route)
                }
        }
        .floatingPlayerBar(store: playerBarStore, playerExpanded: $playerExpanded, isHidden: isSearchFieldActive)
    }
}

private extension View {
    /// Reserves space for, and hosts, this tab's own instance of the collapsed player bar —
    /// see `AppTabView`'s doc for why per-tab rather than shared. The native `MiniPlayerView`
    /// is the visible/interactive layer (`.safeAreaInset`); `FloatingBarSideEffectsController`
    /// is a fixed-height, non-hit-testable `.background` behind it, purely for the toast/
    /// volume-hint/deep-link side effects that have no other home (see `ComposeScreenHosts.kt`).
    /// Must be `.background`, not `.overlay` — `.overlay` draws in *front*, and
    /// `AppShellChrome`'s opaque `Modifier.background(...)` on the Compose side would paint
    /// over and completely hide the native mini player underneath it.
    ///
    /// `isHidden` (only ever true on the Search tab, while its search field has focus) skips
    /// just the native mini player — otherwise it renders squeezed directly above the
    /// keyboard. The side-effects host stays mounted regardless, so toasts/deep-links still work.
    func floatingPlayerBar(store: PlayerBarStore, playerExpanded: Binding<Bool>, isHidden: Bool = false) -> some View {
        safeAreaInset(edge: .bottom) {
            if !isHidden {
                MiniPlayerView(store: store) { playerExpanded.wrappedValue = true }
            }
        }
        .background(alignment: .bottom) {
            ComposeHostView(makeController: {
                ComposeScreenHostsKt.FloatingBarSideEffectsController(
                    onExpand: { playerExpanded.wrappedValue = true }
                )
            })
            .frame(height: MiniPlayerView.reservedHeight)
            .allowsHitTesting(false)
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
