import SwiftUI
import UIKit
import ComposeApp

/// Wraps a Kotlin `UIViewController` factory (`SettingsAppController`,
/// `MainTabHostView`'s `MainAppController`, …) for SwiftUI. A fresh
/// controller — and fresh Compose composition/ViewModels — is created each
/// time SwiftUI recreates this view (e.g. `router.destination` flipping),
/// matching what the old `TopLevelNavRoot`'s `backStack.clear();
/// backStack.add(...)` already did: switching between Main and Settings has
/// always discarded each side's state, so this isn't a new loss. Internal
/// rather than private — `MainTabHostView.swift` reuses it too.
struct ComposeHostView: UIViewControllerRepresentable {
    let makeController: () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController { makeController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// Replaces `ContentView`'s old direct Compose host. Owns exactly what
/// `TopLevelNavRoot.kt` used to own — the Main/Settings switch, the
/// auto-login splash, the reconnection banner, and the schema-compatibility
/// warning — natively, reading all four from the same `AppRootRouter` /
/// `SchemaVersionWarningViewModel` singletons. `TopLevelNavRoot.kt`,
/// `ConnectionStatusBanner.kt`, and `AutoLoginSplash.kt` are gone (this
/// superseded them entirely — Android is gone too, so nothing else rendered
/// them); `App.kt` kept only `AppLifecycleObserver`, still shared with the
/// hosted screens below. See `ComposeScreenHosts.kt` for what's still Compose
/// underneath each side of the switch, and why (the floating player bar in
/// particular isn't part of this slice).
struct AppShellRootView: View {

    @State private var router = AppRouter()

    // Transient hide for the dismissible SERVER_AHEAD warning; reset whenever
    // a fresh warning arrives (including a fresh CLIENT_INCOMPATIBLE, which
    // never reads this — its alert has no dismiss action). Mirrors the
    // `hidden`/`LaunchedEffect(warning)` pair in App.kt's Compose dialog.
    @State private var dismissedSchemaWarning = false

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
        .onChange(of: schemaWarningIdentity) { dismissedSchemaWarning = false }
        .alert(
            schemaWarningTitle,
            isPresented: schemaAlertPresented,
            presenting: router.schemaWarning,
            actions: schemaAlertActions,
            message: { Text(schemaWarningMessage(for: $0)) }
        )
    }

    /// `.onChange` needs an `Equatable` key; the Kotlin enum instances compare
    /// fine with `==` (they're `KotlinEnum`-backed), so this just needs a
    /// Swift-native `Equatable` wrapper around "no warning vs. which case".
    private var schemaWarningIdentity: String? {
        guard let warning = router.schemaWarning else { return nil }
        return warning == .clientIncompatible ? "clientIncompatible" : "serverAhead"
    }

    private var schemaAlertPresented: Binding<Bool> {
        Binding(
            get: {
                guard let warning = router.schemaWarning else { return false }
                // CLIENT_INCOMPATIBLE is terminal — always shown, no dismiss.
                return warning == .clientIncompatible || !dismissedSchemaWarning
            },
            set: { isPresented in
                if !isPresented { dismissedSchemaWarning = true }
            }
        )
    }

    private var schemaWarningTitle: String {
        guard let warning = router.schemaWarning else { return "" }
        return warning == .clientIncompatible
            ? String(localized: "schema_incompatible_dialog_title")
            : String(localized: "schema_version_dialog_title")
    }

    private func schemaWarningMessage(for warning: SchemaWarning) -> String {
        warning == .clientIncompatible
            ? String(localized: "schema_incompatible_dialog_message")
            : String(localized: "schema_version_dialog_message")
    }

    @ViewBuilder
    private func schemaAlertActions(for warning: SchemaWarning) -> some View {
        if warning == .clientIncompatible {
            Button(String(localized: "schema_incompatible_dialog_exit")) {
                // iOS has no programmatic hard-exit API; suspending (backgrounding)
                // is the same platform-native behavior exitApp() uses on the
                // Compose side (ui/compose/nav/PlatformExit.ios.kt).
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
            }
        } else {
            Button(String(localized: "schema_version_dialog_confirm")) {
                dismissedSchemaWarning = true
            }
        }
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
            MainTabHostView()
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
