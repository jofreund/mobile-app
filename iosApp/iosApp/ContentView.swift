import UIKit
import SwiftUI
import ComposeApp

/// Legacy single-entry Compose host — `App()`'s whole tree, including its own
/// `TopLevelNavRoot` Main/Settings switch. Superseded by `AppShellRootView`,
/// which now owns that switch natively (see `Shell/AppRouter.swift`). Kept
/// only because nothing currently depends on deleting it and it's a cheap
/// rollback reference; safe to remove once the shell has proven itself.
struct ComposeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    #if DEBUG
    @State private var showingSpike = false
    #endif

    var body: some View {
        AppShellRootView()
        #if DEBUG
                // Phase A spike entry point. Presented over the app rather than
                // replacing it, so the app is already connected and authenticated
                // when the native views appear. DEBUG-only: the release path is
                // exactly what it was before the spike.
                .overlay(alignment: .bottomTrailing) {
                    Button("Native spike", systemImage: "swift") {
                        showingSpike = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .padding(.trailing, 16)
                    .padding(.bottom, 120)
                }
                .fullScreenCover(isPresented: $showingSpike) {
                    SpikeRootView()
                }
        #endif
    }
}
