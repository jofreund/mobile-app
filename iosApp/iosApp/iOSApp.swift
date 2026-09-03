import SwiftUI
import MusicAssistantKit
import UIKit
import os
import os.log
import os.lock


/// Single-bit flag indicating whether `bootstrapKmp()` has run and Koin is usable.
///
/// It existed for SiriKit, whose intent handlers could run before any scene connected and so
/// needed a way to bail rather than dereference an uninitialized Koin graph. With Siri gone the
/// only readers are the deep-link entry points below, which run after `iOSApp.init()` by
/// construction — so this is now a guard against a situation that can't arise. Kept because it
/// costs nothing and the alternative is asserting an ordering guarantee in a comment; worth
/// revisiting alongside `PendingURL`, which has the same shape.
enum KmpState {
    private static let _isReady = OSAllocatedUnfairLock(initialState: false)
    static var isReady: Bool {
        get { _isReady.withLock { $0 } }
        set { _isReady.withLock { $0 = newValue } }
    }
}

/// Buffers an incoming musicassistant:// URL when it arrives before Koin is
/// initialized (cold-launch-from-deep-link). Replayed by ContentView.onAppear
/// once KmpState.isReady == true. Accessed only from the main thread.
enum PendingURL {
    static var url: URL?
}

/// Single dispatch point for incoming deep links. Three entry forms reach here:
///   - custom scheme  musicassistant://auth/callback   → OAuth (peeled off)
///   - custom scheme  musicassistant://app/<page>       → DeepLinkBus
///   - Universal Link https://…music-assistant.io/app/<page> → DeepLinkBus
/// The OAuth callback is peeled off by shared Kotlin so this path and the in-app
/// auth session agree on what a callback is; everything else is forwarded to the
/// shared DeepLinkBus, which self-filters and ignores anything it doesn't recognize.
///
/// Note this is NOT a fallback for the in-app session: while a session is active the
/// system delivers the custom-scheme redirect only to that session's completion
/// handler, so `.onOpenURL` does not fire. This path serves cold launches and any
/// callback that arrives without a live session.
func handleIncomingURL(_ url: URL) {
    if KmpHelper.shared.authManager.handleOAuthCallbackUrl(urlString: url.absoluteString) { return }
    KmpHelper.shared.handleDeepLink(urlString: url.absoluteString)
}

/// Kept only for the scene-configuration hook SwiftUI needs; the CarPlay branch that used to
/// live here (returning `CarPlaySceneDelegate` for `CPTemplateApplicationSceneSessionRoleApplication`)
/// and the SiriKit `handlerFor` both went with those integrations.
class AppDelegate: NSObject, UIApplicationDelegate {
}

#if DEBUG
/// Forwards Kermit logs (via the KMP `OsLogSink` bridge) to the unified log with
/// `privacy: .public`, for local development
final class OsLogSinkImpl: NSObject, OsLogSink {
    private let subsystem = Bundle.main.bundleIdentifier ?? "com.jofreund.taktgeber"

    func log(severity: String, tag: String, message: String) {
        let logger = os.Logger(subsystem: subsystem, category: tag)
        let level: OSLogType
        switch severity {
        case "Verbose", "Debug": level = .debug
        case "Info":             level = .info
        case "Warn":             level = .default
        case "Error":            level = .error
        case "Assert":           level = .fault
        default:                 level = .default
        }
        logger.log(level: level, "\(message, privacy: .public)")
    }
}
#endif

@main
struct iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Drives `ServiceClient`'s foreground/background reporting, which decides when the
    /// WebSocket may idle. This used to come from `App.kt`'s `AppLifecycleObserver`, reading
    /// Compose's own `LifecycleOwner` — the last thing keeping a Compose host mounted.
    ///
    /// `.active` and `.background` stand in for that observer's `ON_START`/`ON_STOP`.
    /// `.inactive` is deliberately ignored: it fires for the app switcher, Control Center and
    /// notification-shade pulls, none of which mean the app stopped, and treating them as
    /// background would tear the connection down every time someone glanced at a notification.
    @Environment(\.scenePhase) private var scenePhase

    /// Brings up the local (Sendspin) player's audio sink and Now Playing owner when — and only
    /// when — the feature is on. Kotlin reaches the sink through `PlatformPlayerProvider`, which
    /// holds it unretained, so this keeps the strong reference for the process lifetime.
    private let localPlayer = LocalPlayerActivation()

    /// Strong ref: `ASWebAuthenticationSession` cancels itself when its owner deallocates,
    /// so the handler must outlive every login attempt.
    private let oauthWebSession = OAuthWebSession()

    /// Mirrors the selected player into the lock screen / Dynamic Island Live Activity. Lives
    /// here rather than in a view: it must observe playerBarState for the whole process
    /// lifetime — including background launches from the activity's own play/pause intent,
    /// where no view ever appears.
    private let playerActivityController = PlayerActivityController()

    init() {
        #if DEBUG
        // Route Kermit logs to the unified log un-redacted during development
        // Must run before bootstrapKmp() so init-time logs reach the sink.
        OsLogSinkProvider.shared.sink = OsLogSinkImpl()
        #endif

        // KMP/Koin init runs here rather than in a SwiftUI lifecycle callback. That was once
        // load-bearing — a CarPlay-only cold launch connected no `WindowGroup`, so anything
        // hung off `ContentView.onAppear` never ran — and with CarPlay gone there is only the
        // one launch path left. Still the right place: `init()` is the earliest point, and
        // everything below depends on Koin being up.
        MainViewControllerKt.bootstrapKmp()
        KmpState.isReady = true

        // No `translations/set_locale` here. Music Assistant does localize server-side — the
        // server resolves curated names to the connection's locale — but that landed after
        // 2.9.11 and is unreleased, so asking produces an `Invalid command` answer, which
        // `RpcEngine` logs at error level on every launch. `RecommendationRowTitle` covers the
        // rows that matter meanwhile. Recover the probe with `git show 844a2c0d` when a server
        // that answers it ships.

        // Makes `mawebrtc://` artwork URLs resolvable through the standard URL
        // loading system (and therefore AsyncImage/URLSession). Must follow
        // bootstrapKmp() — loads dispatch into Koin-resolved Kotlin.
        MAWebRTCURLProtocol.registerOnce()

        // App-wide setup, so it belongs beside bootstrapKmp() rather than in a SwiftUI
        // callback. It used to be installed from `ContentView.onAppear` on the belief that
        // presenting needed a live scene; the handler resolves its presentation window
        // lazily, at present time, so it has nothing to wait for here.
        KmpHelper.shared.authManager.oauthHandler = oauthWebSession

        // Must run for background launches too (a Live Activity intent tap cold-launches the
        // process with no scene), so init — not a view callback — is the only correct place.
        playerActivityController.start()

        // The local player's Swift half is built on demand from the Sendspin setting, which
        // lives in the Kotlin graph — so this must follow bootstrapKmp(). With the toggle off
        // (the default) nothing here touches the audio session at all.
        localPlayer.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    if let pending = PendingURL.url {
                        PendingURL.url = nil
                        handleIncomingURL(pending)
                    }
                }
                .onOpenURL { url in
                    // Custom-scheme links (musicassistant://…).
                    if KmpState.isReady {
                        handleIncomingURL(url)
                    } else {
                        PendingURL.url = url
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal Links (https://…music-assistant.io/app/…) arrive
                    // as a web-browsing NSUserActivity, not via onOpenURL.
                    guard let url = activity.webpageURL else { return }
                    if KmpState.isReady {
                        handleIncomingURL(url)
                    } else {
                        PendingURL.url = url
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                KmpHelper.shared.onAppForeground()
                playerActivityController.scenePhaseChanged(active: true)
            case .background:
                KmpHelper.shared.onAppBackground()
                playerActivityController.scenePhaseChanged(active: false)
            case .inactive: break
            @unknown default: break
            }
        }
    }
}
