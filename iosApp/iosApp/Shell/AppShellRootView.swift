import SwiftUI
import ComposeApp

/// Wraps a Kotlin `UIViewController` factory (`MainAppController`,
/// `SettingsAppController`, …) for SwiftUI. A fresh controller — and fresh
/// Compose composition/ViewModels — is created each time SwiftUI recreates
/// this view (e.g. `router.destination` flipping), matching what the old
/// `TopLevelNavRoot`'s `backStack.clear(); backStack.add(...)` already did:
/// switching between Main and Settings has always discarded each side's
/// state, so this isn't a new loss.
private struct ComposeHostView: UIViewControllerRepresentable {
    let makeController: () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController { makeController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// Replaces `ContentView`'s old direct `MainViewController()` host. Owns
/// exactly what `TopLevelNavRoot.kt` used to own — the Main/Settings switch,
/// the auto-login splash, and the reconnection banner — natively, reading
/// all three from the same `AppRootRouter` singleton Compose's version now
/// also defers to. See `ComposeScreenHosts.kt` for what's still Compose
/// underneath each side of the switch, and why (the floating player bar in
/// particular isn't part of this slice).
struct AppShellRootView: View {

    @State private var router = AppRouter()

    var body: some View {
        ZStack {
            content
                .ignoresSafeArea(.keyboard) // Compose has its own keyboard handler
                .ignoresSafeArea(.container) // Compose still owns full-screen chrome on this side

            VStack(spacing: 0) {
                if let bannerState = router.bannerState {
                    ReconnectionBanner(state: bannerState) { router.cancelReconnect() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.2), value: router.bannerState != nil)

            if router.splashVisible {
                AutoLoginSplashView { router.cancelAutoLogin() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: router.splashVisible)
        .task { router.start() }
    }

    @ViewBuilder
    private var content: some View {
        // Both switch cases produce the same ComposeHostView struct type, so
        // without an explicit identity SwiftUI treats a destination change as
        // an update to the existing view (calling the representable's empty
        // updateUIViewController) rather than a replacement — the old
        // controller would just stay mounted. .id() forces recreation.
        switch router.destination {
        case .main:
            ComposeHostView(makeController: ComposeScreenHostsKt.MainAppController)
                .id("main")
        default:
            // Kotlin-exported enums aren't a closed set to Swift's exhaustiveness
            // checker, so this covers .settings (and anything added later).
            ComposeHostView(makeController: ComposeScreenHostsKt.SettingsAppController)
                .id("settings")
        }
    }
}

// MARK: - Native overlays

/// Native counterpart to `AutoLoginSplash.kt`. Compose's version exists
/// because it also has to render inside the Android/legacy iOS Compose tree;
/// this one gets real `ProgressView` and system materials instead.
private struct AutoLoginSplashView: View {

    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                ProgressView()
                    .controlSize(.large)
                Text(String(localized: "settings_connecting"))
                    .font(.body)
                    .foregroundStyle(.primary)
            }

            VStack {
                Spacer()
                Button(String(localized: "common_cancel"), action: onCancel)
                    .buttonStyle(.bordered)
                    .padding(.bottom, 48)
            }
        }
    }
}

/// Native counterpart to `ConnectionStatusBanner.kt`. No entry debounce here
/// (Compose's 3s `Timings.UI_RETRY_DEBOUNCE` delay before showing) — that
/// existed to avoid flashing during a fast reconnect and is worth carrying
/// over if this reads as noisy in practice; deferred until it's observed to
/// matter on-device.
private struct ReconnectionBanner: View {

    let state: AppBannerState
    let onCancel: () -> Void

    private var text: String {
        if let reconnecting = state as? AppBannerStateReconnecting {
            String(format: String(localized: "banner_reconnecting"), reconnecting.attempt)
        } else {
            String(localized: "banner_no_network")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
            Spacer()
            Button(String(localized: "common_cancel"), action: onCancel)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.top, 44) // clear the status bar / Dynamic Island
        .background(.thinMaterial)
    }
}
