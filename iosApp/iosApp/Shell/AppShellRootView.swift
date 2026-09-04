import SwiftUI
import UIKit
import MusicAssistantKit

/// The root of the app: the Main/Settings switch, the auto-login splash, the reconnection
/// banner, and the terminal schema-incompatibility alert, all read from the one `AppRouter`
/// (whose decisions are `AppRootPolicy`'s). The toast host lives here too, so a message raised
/// while Settings is up still lands (`ToastHost.swift`).
struct AppShellRootView: View {

    /// Started from `iOSApp.init`, not here, so the policy sees session transitions from the
    /// first moment; `.task { start() }` below is only a safety net and is idempotent.
    private let router = AppRouter.shared

    /// Read for one flag: kids mode swaps the tab shell for `KidsFavoritesView` (`content`).
    private let preferences = AppPreferences.shared

    /// The app's one toast host — see `ToastHost.swift` for why there must be exactly one. Held
    /// here rather than in `AppTabView` so a message raised while Settings is up still lands.
    @State private var toasts = ToastPresenter()

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
        .toastHost(toasts)
        .task { router.start() }
        .alert(
            String(localized: "schema_incompatible_dialog_title"),
            isPresented: schemaAlertPresented,
            actions: schemaAlertActions,
            message: { Text(String(localized: "schema_incompatible_dialog_message")) }
        )
    }

    /// `SchemaWarning` has a single case — `clientIncompatible`, which is terminal — so its
    /// presence is the whole condition. There is no dismissal to honour: the only action is
    /// Exit, and a client below the server's floor cannot do anything useful in the meantime.
    /// The dismissible "server ahead" alert this used to also present is gone (see
    /// `SchemaWarning`), and with it the `dismissed`/`identity` bookkeeping that existed
    /// solely to let it be waved away once per connect.
    private var schemaAlertPresented: Binding<Bool> {
        Binding(
            get: { router.schemaWarning != nil },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func schemaAlertActions() -> some View {
        Button(String(localized: "schema_incompatible_dialog_exit")) {
            // iOS has no programmatic hard-exit API; suspending (backgrounding) is the
            // platform-native stand-in.
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
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
                if !presented { router.requestHome() }
            }
        )
    }

    private var content: some View {
        // The tab view is now built once and stays alive behind Settings, where it used to be
        // torn down and recreated on every visit. That's the point — but it also means Home no
        // longer gets a free reload when Settings closes, which is what used to mask its
        // one-shot load having failed while disconnected. `HomeView` reloads on becoming
        // authenticated instead; see the subscription there.
        Group {
            if preferences.kidsModeEnabled {
                // Kids mode is the shell, not a screen over it: the tab view is not built at
                // all while it is on, so nothing underneath fetches or subscribes for nobody.
                // See `.claude/kids-favorites-mode.md`.
                KidsFavoritesView()
            } else {
                AppTabView()
                    // Compose had its own keyboard handler on this side — SettingsView is now
                    // substantially native (Phase E4 part 2's real TextFields) and must NOT get
                    // this: it was found to suppress the keyboard from appearing for native
                    // fields entirely (iOS 26 beta).
                    .ignoresSafeArea(.keyboard)
            }
        }
        // `.ignoresSafeArea(.container)` was here too, from when this side was a single
        // full-screen Compose host drawing its own chrome. Nothing here is Compose now, and
        // it suppressed the bottom container safe area for the whole tab subtree.
        .fullScreenCover(isPresented: settingsPresented) {
            SettingsView()
        }
    }
}

// MARK: - Native overlays

/// The cold-launch auto-login splash: real `ProgressView` and system materials.
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

/// The reconnection banner. No entry debounce (the Compose original waited 3 s before
/// showing, to avoid flashing during a fast reconnect) — worth adding if this reads as noisy
/// in practice; deferred until it's observed to matter on-device.
private struct ReconnectionBanner: View {

    let state: AppBannerState
    let onCancel: () -> Void

    private var text: String {
        switch state {
        case .reconnecting(let attempt):
            String(format: String(localized: "banner_reconnecting"), attempt)
        case .noNetwork:
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
