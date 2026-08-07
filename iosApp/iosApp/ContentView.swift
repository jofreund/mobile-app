import UIKit
import SwiftUI
import ComposeApp

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
        ComposeView()
                .ignoresSafeArea(.keyboard) // Compose has own keyboard handler
                .ignoresSafeArea(.container) // Extend to screen edges (removes white areas)
        #if DEBUG
                // Phase A spike entry point. Presented over the Compose UI rather
                // than replacing it, so the app is already connected and
                // authenticated when the native views appear. DEBUG-only: the
                // release path is exactly what it was before the spike.
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
