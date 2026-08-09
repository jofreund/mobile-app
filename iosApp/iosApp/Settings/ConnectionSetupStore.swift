import SwiftUI
import ComposeApp
import os

/// Auth/connection failures reaching Swift used to be dropped on the floor, which made a
/// stalled sign-in indistinguishable from one still in flight. Kermit's own logs already
/// reach this same unified log through `OsLogSinkImpl`, so these land alongside them.
private let connectionLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.music-assistant.client",
    category: "ConnectionSetup"
)

/// Drives every `ConnectionSetupView` section — Direct/WebRTC connect forms, connection
/// history, and the login/OAuth panel. Same shape as `AppRouter.swift`: turns Kotlin
/// `NativeStateFlow`/one-shot bridge calls into `@Observable` state, while every actual
/// decision of protocol consequence (server-ID-mismatch detection, per-server token
/// lifecycle, silent-vs-surfaced auth retry) stays in `AuthenticationManager`/`ServiceClient`,
/// reached only through `KmpHelper`.
///
/// The provider-loading policy and auto-reconnect effect below are **not** protocol logic —
/// they're the same UI-orchestration `AuthenticationViewModel`/`SettingsScreen.kt`'s
/// `LaunchedEffect`s already do on top of the real state machine, ported here 1:1 so Swift
/// owns the "when do I ask for the provider list" / "when do I retry a failed connection"
/// policy the same way Compose's ViewModel layer already did.
@Observable
@MainActor
final class ConnectionSetupStore {

    private(set) var authState: AuthState?
    private(set) var providers: [AuthProvider] = []
    private(set) var history: [ConnectionHistoryEntry] = []
    private(set) var preferredMethod: String = "direct"
    var remoteId: String = "" {
        didSet {
            guard remoteId != oldValue else { return }
            KmpHelper.shared.setWebrtcRemoteId(remoteId: remoteId)
        }
    }

    // Direct-connect form fields, seeded once from `savedConnectionInfo()`.
    var host: String = ""
    var port: String = ""
    var isTls: Bool = false

    // Builtin-login form fields — ephemeral, matches `AuthenticationViewModel`'s plain
    // `MutableStateFlow`, not persisted.
    var username: String = ""
    var password: String = ""
    private(set) var loginError: String?

    private var autoReconnectAttempted = false

    private var authStateSub: Cancellable?
    private var historySub: Cancellable?
    private var preferredMethodSub: Cancellable?
    private var remoteIdSub: Cancellable?
    private var providersLoadHandle: Cancellable?

    /// Resolves the local-network permission while the form is on screen, so tapping Connect
    /// isn't what raises the prompt (which used to fail that first attempt). See
    /// `LocalNetworkPermission.swift`.
    private let localNetworkPrimer = LocalNetworkPermissionPrimer()

    func start() {
        guard authStateSub == nil else { return }

        localNetworkPrimer.prime()

        if let saved = KmpHelper.shared.savedConnectionInfo() {
            host = saved.host
            port = String(saved.port)
            isTls = saved.isTls
        } else {
            // Fresh install: fill the form in rather than only hinting at these through
            // placeholders (which is all Compose ever did), so the common case — a Music
            // Assistant add-on on Home Assistant's default host and port — is one tap.
            // Straight from the shared core's own Defaults, so these can't drift from
            // whatever the Kotlin connection path considers standard.
            host = Defaults.shared.URI
            port = String(Defaults.shared.PORT)
        }

        authStateSub = KmpHelper.shared.authState.subscribe { [weak self] state in
            self?.handleAuthStateChange(state)
        }
        historySub = KmpHelper.shared.connectionHistory.subscribe { [weak self] value in
            // NativeStateFlow<T>'s generic T loses Swift's automatic NSArray/NSString bridging
            // (same reason AppRouter.swift unboxes KotlinBoolean via .boolValue) — explicit
            // cast needed here, unlike the class-typed NativeStateFlows (SessionState, etc.).
            self?.history = (value as? [ConnectionHistoryEntry]) ?? []
        }
        preferredMethodSub = KmpHelper.shared.preferredConnectionMethod.subscribe { [weak self] value in
            self?.preferredMethod = (value as? String) ?? "direct"
        }
        remoteIdSub = KmpHelper.shared.webrtcRemoteId.subscribe { [weak self] value in
            // Avoid re-triggering setWebrtcRemoteId's didSet from our own echoed value.
            guard let self, let value = value as? String, value != self.remoteId else { return }
            self.remoteId = value
        }
    }

    func stop() {
        localNetworkPrimer.cancel()
        authStateSub?.cancel()
        historySub?.cancel()
        preferredMethodSub?.cancel()
        remoteIdSub?.cancel()
        providersLoadHandle?.cancel()
        authStateSub = nil
        historySub = nil
        preferredMethodSub = nil
        remoteIdSub = nil
        providersLoadHandle = nil
    }

    private func handleAuthStateChange(_ state: AuthState?) {
        authState = state
        // Mirrors AuthenticationPanel's LaunchedEffect(authState): clear the error only once
        // authenticated; a fresh Error overwrites it; Idle/Loading leave a prior error visible.
        if state is AuthState.Authenticated {
            loginError = nil
        } else if let error = state as? AuthState.Error {
            loginError = error.message
        }
    }

    /// Replicates `AuthenticationViewModel`'s `autoSource` branch table, plus the
    /// `SettingsScreen.kt` auto-reconnect `LaunchedEffect`. Call from the view's
    /// `.onChange(of: sessionState)`.
    func onSessionStateChange(_ state: SessionState?) {
        switch state {
        case is SessionState.Disconnected:
            providersLoadHandle?.cancel()
            providersLoadHandle = nil
            providers = []
            attemptAutoReconnect(state)

        case let connected as SessionState.Connected:
            guard let awaitingAuth = connected.dataConnectionState as? DataConnectionStateAwaitingAuth else {
                return // Authenticated (or AwaitingServerInfo) — keep current providers, no-op.
            }
            if awaitingAuth.authProcessState is AuthProcessStateFailed {
                return // Preserve the displayed error; Retry explicitly bypasses this.
            }
            loadProviders()

        default:
            break // Connecting / Reconnecting — no-op, matches autoSource.
        }
    }

    /// Only on `Disconnected.Error`, only once per store lifetime, skipped for WebRTC, and
    /// bailing out if the form fields were edited since the saved connection info — verbatim
    /// port of `SettingsScreen.kt`'s `LaunchedEffect(sessionState)`.
    private func attemptAutoReconnect(_ state: SessionState?) {
        guard state is SessionState.DisconnectedError,
              let saved = KmpHelper.shared.savedConnectionInfo(),
              !autoReconnectAttempted,
              preferredMethod != "webrtc"
        else { return }

        let userChangedConnectionInfo = host != saved.host || port != String(saved.port) || isTls != saved.isTls
        guard !userChangedConnectionInfo else { return }

        autoReconnectAttempted = true
        attemptConnection()
    }

    /// The actual fetch, shared by both the auto path (`onSessionStateChange`, gated on the
    /// Failed-state suppression there) and the UI's Retry button (unconditional — mirrors
    /// `retrySource` bypassing that same suppression).
    func loadProviders() {
        providersLoadHandle?.cancel()
        providersLoadHandle = KmpHelper.shared.fetchAuthProviders(
            completion: { [weak self] result in self?.providers = result ?? [] },
            onError: { error in
                connectionLog.error("fetchAuthProviders failed: \(String(describing: error), privacy: .public)")
            }
        )
    }

    /// Mirrors `AuthenticationViewModel.login` exactly: builtin dispatches to the credentials
    /// form, everything else resolves an OAuth URL then hands off to the system browser via
    /// `startOAuthFlow` (already public on `authManager`, no bridge needed).
    func login(provider: AuthProvider) {
        if provider.type == "builtin" {
            _ = KmpHelper.shared.loginWithCredentials(
                providerId: provider.id,
                username: username,
                password: password,
                completion: { _ in },
                onError: { error in
                    connectionLog.error("loginWithCredentials failed: \(String(describing: error), privacy: .public)")
                }
            )
        } else {
            _ = KmpHelper.shared.getOAuthUrl(
                providerId: provider.id,
                completion: { url in
                    guard let url else {
                        connectionLog.error("getOAuthUrl returned no URL — OAuth cannot start")
                        return
                    }
                    _ = KmpHelper.shared.authManager.startOAuthFlow(oauthUrl: url)
                },
                onError: { error in
                    connectionLog.error("getOAuthUrl failed: \(String(describing: error), privacy: .public)")
                }
            )
        }
    }

    func logout() {
        _ = KmpHelper.shared.authLogout {}
    }

    func attemptConnection() {
        KmpHelper.shared.attemptConnection(host: host, port: port, isTls: isTls)
    }

    func attemptWebRTCConnection() {
        KmpHelper.shared.attemptWebRTCConnection(remoteId: remoteId)
    }

    func setPreferredMethod(_ method: String) {
        KmpHelper.shared.setPreferredConnectionMethod(method: method)
    }

    /// Mirrors `ConnectionMethodTabs`' `onFill` — only populates fields/switches tab, never
    /// auto-connects.
    func fillFromHistory(_ entry: ConnectionHistoryEntry) {
        if entry.type == .direct, let info = entry.connectionInfo {
            host = info.host
            port = String(info.port)
            isTls = info.isTls
            setPreferredMethod("direct")
        } else if entry.type == .webrtc, let id = entry.remoteId {
            remoteId = id
            setPreferredMethod("webrtc")
        }
    }

    func removeFromHistory(_ entry: ConnectionHistoryEntry) {
        KmpHelper.shared.removeFromHistory(entry: entry)
    }

    func hasCredentialsForDirect() -> Bool {
        guard let port = Int32(port) else { return false }
        return KmpHelper.shared.hasCredentialsForDirect(host: host, port: port, isTls: isTls)
    }

    func hasCredentialsForWebRTC() -> Bool {
        KmpHelper.shared.hasCredentialsForWebRTC(remoteId: remoteId)
    }
}
