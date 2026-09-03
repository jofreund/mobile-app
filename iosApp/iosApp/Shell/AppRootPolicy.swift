import Foundation

/// Which top-level surface is showing: the authenticated tab shell, or connection setup.
enum AppRootDestination: Equatable {
    case main
    case settings
}

/// The reconnection banner's two states, or nothing (no banner).
enum AppBannerState: Equatable {
    case reconnecting(attempt: Int)
    case noNetwork
}

/// Schema-compatibility warning for the connected server.
///
/// One case, deliberately. There was a second — `serverAhead`, a dismissible "the server speaks
/// a newer schema than the app" alert — and it was noise: it fired on every launch against any
/// server newer than the client's tested-against version while playback, library, queue and
/// recommendations all worked, because nothing in this client gates on a schema that high. The
/// only fix available to a user was to dismiss it again. Upstream reached the same conclusion
/// and deleted it (music-assistant/mobile-app@c9e03d71).
enum SchemaWarning: Equatable {
    /// Client speaks a schema below the server's minimum supported — unusable. Terminal (must exit).
    case clientIncompatible
}

/// What the root policy reads out of Kotlin's `SessionState`, and nothing else.
///
/// Pure Swift on purpose. The test target compiles app sources directly and links nothing from
/// `MusicAssistantKit`, so a policy written over the Kotlin sealed class could not be tested
/// there. `AppRouter` does the one-way mapping from the Kotlin state; the policy and its tests
/// never see a Kotlin type.
enum RootSession: Equatable {

    enum AuthProcess: Equatable {
        case notStarted
        case inProgress
        case loggedOut
        case failed
    }

    enum DataConnection: Equatable {
        case awaitingServerInfo
        case awaitingAuth
        case authenticated
    }

    struct Connected: Equatable {
        var dataConnection: DataConnection
        /// Carried separately from `dataConnection`: Kotlin's `ConnectionData` holds the auth
        /// process alongside the data-connection state, and the rules below read both.
        var authProcess: AuthProcess
        var wasAutoLogin: Bool
        /// Whether a token is saved for this server — `AuthenticationManager.hasSavedTokenFor`
        /// at the moment the state arrived.
        var hasSavedToken: Bool
        /// The server's `min_supported_schema_version`, once its hello has arrived.
        var minSupportedSchemaVersion: Int?
    }

    /// The transient pre-connection moment, always followed by `connecting` in real usage.
    case disconnectedInitial
    /// Backgrounded: preserve the current screen for an instant foreground reconnect.
    case disconnectedBackgrounded
    /// ByUser, NoServerData, Error — resolved outcomes the user should act on.
    case disconnectedResolved
    case connecting
    case reconnecting(attempt: Int, isOnline: Bool, minSupportedSchemaVersion: Int?)
    case connected(Connected)
}

/// Single source of truth for what the top level of the app looks like right now: which screen
/// (the main tab shell vs. Settings), whether the cold-launch auto-login splash is up, and
/// whether a reconnection banner should show.
///
/// This is the policy that Kotlin's `AppRootRouter` used to hold (itself an extraction of the
/// Compose `TopLevelNavRoot`'s `LaunchedEffect`s). It moved to Swift because it decides what
/// SwiftUI shows and nothing else reads it; a pure value type here is testable without a
/// coroutine test dispatcher and costs no bridge traffic. `AppRouter` owns the one instance,
/// feeds it session states, and publishes its outputs as `@Observable` state.
struct AppRootPolicy: Equatable {

    let willAutoLoginOnLaunch: Bool

    private(set) var destination: AppRootDestination
    private(set) var splashVisible = false
    private(set) var bannerState: AppBannerState?

    /// Latches closed the first time the splash resolves (success or failure) so a later
    /// user-initiated reconnect — which revisits Connecting/Initial-shaped states — never brings
    /// it back. Process state, not something the UI projects.
    private var splashDismissedLatch = false

    /// Computes the initial destination from `initial` and applies it, so a reader immediately
    /// after construction never sees a placeholder.
    init(willAutoLoginOnLaunch: Bool, initial: RootSession) {
        self.willAutoLoginOnLaunch = willAutoLoginOnLaunch
        destination = Self.initialDestination(for: initial, willAutoLoginOnLaunch: willAutoLoginOnLaunch)
        apply(initial)
    }

    mutating func apply(_ session: RootSession) {
        updateSplash(session)
        updateDestination(session)
        bannerState = switch session {
        case .reconnecting(let attempt, let isOnline, _):
            isOnline ? .reconnecting(attempt: attempt) : .noNetwork
        default:
            nil
        }
    }

    /// Permanently dismisses the splash. Tearing the connection down is the caller's side
    /// effect (`AppRouter.cancelAutoLogin`), not this value's.
    mutating func cancelAutoLogin() {
        splashDismissedLatch = true
        splashVisible = false
    }

    /// User-initiated navigation to Settings, independent of session state — unlike
    /// `updateDestination`'s rules, this fires regardless of connection state.
    mutating func requestSettings() {
        destination = .settings
    }

    /// User-initiated return to the main shell (Settings' close button). Callers are expected to
    /// only offer this while authenticated, so it isn't re-checked here.
    mutating func requestHome() {
        destination = .main
    }

    /// A server only becomes incompatible when its floor rises above what this client speaks.
    /// Merely trailing the server's *current* schema is not a fault — see `SchemaWarning`.
    static func schemaWarning(for session: RootSession, localSchemaVersion: Int) -> SchemaWarning? {
        let floor: Int? = switch session {
        case .connected(let connected): connected.minSupportedSchemaVersion
        case .reconnecting(_, _, let minSupported): minSupported
        default: nil
        }
        guard let floor, localSchemaVersion < floor else { return nil }
        return .clientIncompatible
    }

    // MARK: - Rules

    private static func initialDestination(for session: RootSession, willAutoLoginOnLaunch: Bool) -> AppRootDestination {
        if case .connected(let connected) = session, connected.dataConnection == .authenticated {
            return .main
        }
        return willAutoLoginOnLaunch ? .main : .settings
    }

    private mutating func updateSplash(_ session: RootSession) {
        let shaped: Bool = switch session {
        case .disconnectedInitial, .connecting:
            true
        case .connected(let connected):
            connected.dataConnection != .authenticated && connected.authProcess != .failed
        default:
            false
        }
        splashVisible = !splashDismissedLatch && willAutoLoginOnLaunch && shaped

        let terminal: Bool = switch session {
        case .connected(let connected):
            connected.dataConnection == .authenticated || connected.authProcess == .failed
        case .disconnectedResolved:
            true
        default:
            false
        }
        if terminal { splashDismissedLatch = true }
    }

    private mutating func updateDestination(_ session: RootSession) {
        let target: AppRootDestination? = switch session {
        case .reconnecting, .connecting:
            nil // preserve current screen
        case .disconnectedBackgrounded, .disconnectedInitial:
            // Backgrounded: preserve, for instant foreground reconnect. Initial: forcing Settings
            // here would fight the initial destination's bias toward Main when a saved token
            // means auto-login is about to run, for no benefit (nothing has failed yet).
            nil
        case .disconnectedResolved:
            .settings
        case .connected(let connected):
            if connected.dataConnection == .authenticated && connected.wasAutoLogin {
                .main
            } else if connected.authProcess == .failed {
                .settings
            } else if connected.dataConnection == .awaitingAuth,
                      connected.authProcess == .notStarted,
                      !connected.hasSavedToken {
                // Connected, but no token to auto-login with (e.g. the server revoked it and
                // AuthenticationManager cleared it). Without this the user stays on Main with
                // every request timing out.
                .settings
            } else {
                nil // other Connected sub-states don't force a screen
            }
        }
        guard let target, destination != target else { return }
        destination = target
    }
}
