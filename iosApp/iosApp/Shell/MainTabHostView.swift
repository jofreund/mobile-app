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
/// destination Swift owns instead of Compose's own `MultiBackStack`. See
/// `ComposeScreenHosts.kt`'s doc for the full picture: everything *except*
/// ItemDetails (tabs, Library/Browse/ItemList push navigation, the floating
/// player bar) still lives inside the one Compose tree `MainAppController()`
/// hosts; only a tap that used to push `MainNav.ItemDetails` now surfaces
/// here instead.
///
/// `ItemDetailsPlaceholderView` below is deliberately not the real detail
/// screen — building SwiftUI's `ItemDetailsScreen` equivalent (hero artwork,
/// tabs, track lists, similar-artists sheet, ~1,274 LOC of Compose to port)
/// is its own real chunk of work. This proves the harder, novel part first:
/// a live Compose screen, still driving real playback and real data, handing
/// off navigation to a native `NavigationStack` that pushes a native view —
/// with nothing about Home/Library/Search/the player bar disturbed.
struct MainTabHostView: View {

    @State private var path: [ItemDetailsRoute] = []

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
                    ItemDetailsPlaceholderView(route: route)
                }
        }
    }

    private func makeMainController() -> UIViewController {
        ComposeScreenHostsKt.MainAppController { [self] itemId, mediaType, providerId in
            path.append(ItemDetailsRoute(itemId: itemId, mediaType: mediaType, providerId: providerId))
        }
    }
}

private struct ItemDetailsPlaceholderView: View {

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
