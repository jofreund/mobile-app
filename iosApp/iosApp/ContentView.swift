import SwiftUI

struct ContentView: View {

    /// Owned here, at the window root, and shared down via the environment so Settings' picker
    /// reads the same value it writes. `ThemeStore` applies the setting to the window itself
    /// rather than through `.preferredColorScheme` — see its doc for why that modifier was
    /// dropped after it turned out to be a one-way trip into dark mode.
    @State private var theme = ThemeStore()

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AppShellRootView()
            .environment(theme)
            .task { theme.start() }
            // A window connected or restored after launch comes back on the system style, so the
            // setting is re-asserted rather than assumed to have stuck.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { theme.apply() }
            }
    }
}
