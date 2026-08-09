import SwiftUI

struct ContentView: View {

    /// Owned here, at the window root, because `.preferredColorScheme` applies to a view and
    /// everything it presents — putting it any deeper would leave sheets and full-screen covers
    /// (Settings, the expanded player) on the system scheme while the app behind them changed.
    /// Shared down via the environment so Settings' picker reads the same value it writes.
    @State private var theme = ThemeStore()

    var body: some View {
        AppShellRootView()
            .environment(theme)
            .preferredColorScheme(theme.colorScheme)
            .task { theme.start() }
    }
}
