import SwiftUI
import ComposeApp

/// The Search tab's root — Phase E3. Placeholder for now while the shell rework
/// (`AppTabView.swift`, `ComposeScreenHosts.kt`) lands and gets verified; the real
/// search field/filters/results port replaces this body next.
struct SearchView: View {
    var body: some View {
        ContentUnavailableView(
            String(localized: "nav_search"),
            systemImage: "magnifyingglass"
        )
        .navigationTitle(String(localized: "nav_search"))
        .navigationBarTitleDisplayMode(.large)
    }
}
