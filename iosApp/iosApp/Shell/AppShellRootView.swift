import SwiftUI
import UIKit
import ComposeApp

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

    /// Settings is presented *over* the app rather than swapped in for it, so it reads as a
    /// modal task you close (with an ✕) rather than a place you navigate to and back from.
    ///
    /// `.fullScreenCover`, not `.sheet`, on purpose: the router starts here on a fresh install
    /// (`computeInitialDestination` picks Settings when there's nothing to auto-login with), and
    /// a sheet's swipe-to-dismiss would let someone flick past connection setup onto an app with
    /// no server. There's no interactive dismissal to guard against here — only the ✕, which is
    /// exactly the affordance the old back button had.
    private var settingsPresented: Binding<Bool> {
        Binding(
            get: { router.destination != .main },
            set: { presented in
                // Only meaningful on dismissal; presentation is driven by the router.
                if !presented { KmpHelper.shared.requestHome() }
            }
        )
    }

    private var content: some View {
        // The tab view is now built once and stays alive behind Settings, where it used to be
        // torn down and recreated on every visit. That's the point — but it also means Home no
        // longer gets a free reload when Settings closes, which is what used to mask its
        // one-shot load having failed while disconnected. `HomeView` reloads on becoming
        // authenticated instead; see the subscription there.
        AppTabView()
            // Compose had its own keyboard handler on this side — SettingsView is now
            // substantially native (Phase E4 part 2's real TextFields) and must NOT get this:
            // it was found to suppress the keyboard from appearing for native fields entirely
            // (iOS 26 beta).
            .ignoresSafeArea(.keyboard)
            // `.ignoresSafeArea(.container)` was here too, from when this side was a single
            // full-screen Compose host drawing its own chrome. Nothing here is Compose now, and
            // it suppressed the bottom container safe area for the whole tab subtree.
            .fullScreenCover(isPresented: settingsPresented) {
                SettingsView()
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
