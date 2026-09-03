import SwiftUI
import MusicAssistantKit

/// Drives the top-level switch: which screen is showing (the main tab shell vs. connection
/// setup), whether the cold-launch auto-login splash is up, whether a reconnection banner
/// should show, and whether the terminal schema-incompatibility alert must be up.
///
/// The decisions live in `AppRootPolicy`, a pure Swift value. This class is the one place that
/// touches Kotlin for them: it maps `SessionState` to `RootSession`, feeds the policy, and
/// publishes the outputs as `@Observable` state SwiftUI binds to. There is exactly one router,
/// started from `iOSApp.init` right after the Kotlin graph is up — the policy's splash latch is
/// process state, so it has to see the session transitions from the start, not from whenever
/// the root view first appears.
@Observable
@MainActor
final class AppRouter {

    static let shared = AppRouter()

    private(set) var destination: AppRootDestination
    private(set) var splashVisible: Bool
    private(set) var bannerState: AppBannerState?
    private(set) var schemaWarning: SchemaWarning?

    private var policy: AppRootPolicy
    private var subscription: Cancellable?

    private init() {
        let helper = KmpHelper.shared
        // Computed synchronously from the current value, so a reader immediately after
        // construction never sees a placeholder.
        let initial = RootSession(helper.sessionState.value ?? SessionState.DisconnectedInitial())
        let policy = AppRootPolicy(
            willAutoLoginOnLaunch: helper.authManager.willAutoLoginOnLaunch,
            initial: initial
        )
        self.policy = policy
        destination = policy.destination
        splashVisible = policy.splashVisible
        bannerState = policy.bannerState
        schemaWarning = Self.schemaWarning(for: initial)
    }

    /// Starts observing session state. Idempotent; the subscription lives as long as the process.
    func start() {
        guard subscription == nil else { return }
        subscription = KmpHelper.shared.sessionState.subscribe { [weak self] state in
            guard let self, let state else { return }
            let session = RootSession(state)
            self.policy.apply(session)
            self.publish(schemaWarning: Self.schemaWarning(for: session))
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Cancels the in-flight auto-login attempt (splash's Cancel button).
    func cancelAutoLogin() {
        KmpHelper.shared.serviceClient.disconnectByUser()
        policy.cancelAutoLogin()
        publish()
    }

    /// Tears down the connection so the reconnection banner's Cancel button stops the retry loop.
    func cancelReconnect() {
        KmpHelper.shared.serviceClient.disconnectByUser()
    }

    /// User-initiated navigation to Settings, regardless of connection state.
    func requestSettings() {
        policy.requestSettings()
        publish()
    }

    /// User-initiated return to the main shell (Settings' close button).
    func requestHome() {
        policy.requestHome()
        publish()
    }

    // MARK: - Publishing

    /// Writes only what changed: `@Observable` notifies on every set, and the splash and
    /// Settings cover animate on their values.
    private func publish(schemaWarning newWarning: SchemaWarning?? = nil) {
        if destination != policy.destination { destination = policy.destination }
        if splashVisible != policy.splashVisible { splashVisible = policy.splashVisible }
        if bannerState != policy.bannerState { bannerState = policy.bannerState }
        if let newWarning, schemaWarning != newWarning { schemaWarning = newWarning }
    }

    /// Server details arrive before login/autologin, so keying off the session state warns at
    /// the right moment; the alert is up for as long as the warning holds.
    private static func schemaWarning(for session: RootSession) -> SchemaWarning? {
        AppRootPolicy.schemaWarning(
            for: session,
            localSchemaVersion: Int(ServerInfoKt.LOCAL_SCHEMA_VERSION)
        )
    }
}

// MARK: - Kotlin → RootSession

extension RootSession {

    /// The one-way mapping from Kotlin's sealed `SessionState`. Reads exactly what the policy
    /// needs and snapshots `AuthenticationManager.hasSavedTokenFor` while the state is at hand.
    init(_ state: SessionState) {
        switch state {
        case let connected as SessionState.Connected:
            let data = connected.connectionData
            let dataConnection: DataConnection = switch connected.dataConnectionState {
            case is DataConnectionStateAuthenticated: .authenticated
            case is DataConnectionStateAwaitingAuth: .awaitingAuth
            default: .awaitingServerInfo
            }
            self = .connected(
                Connected(
                    dataConnection: dataConnection,
                    authProcess: AuthProcess(data.authProcessState),
                    wasAutoLogin: data.wasAutoLogin,
                    hasSavedToken: KmpHelper.shared.authManager.hasSavedTokenFor(state: connected),
                    minSupportedSchemaVersion: connected.serverInfo?.minSupportedSchemaVersion?.intValue
                )
            )
        case let reconnecting as SessionState.Reconnecting:
            self = .reconnecting(
                attempt: Int(reconnecting.attempt),
                isOnline: reconnecting.isOnline,
                minSupportedSchemaVersion: reconnecting.serverInfo?.minSupportedSchemaVersion?.intValue
            )
        case is SessionState.Connecting:
            self = .connecting
        case is SessionState.DisconnectedInitial:
            self = .disconnectedInitial
        case is SessionState.DisconnectedBackgrounded:
            self = .disconnectedBackgrounded
        default:
            // ByUser, NoServerData, Error.
            self = .disconnectedResolved
        }
    }
}

private extension RootSession.AuthProcess {
    init(_ state: AuthProcessState) {
        self = switch state {
        case is AuthProcessStateFailed: .failed
        case is AuthProcessStateInProgress: .inProgress
        case is AuthProcessStateLoggedOut: .loggedOut
        default: .notStarted
        }
    }
}
