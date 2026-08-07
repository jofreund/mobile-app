import UIKit
import SwiftUI
import ComposeApp

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
