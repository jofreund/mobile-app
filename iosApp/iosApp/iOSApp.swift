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

/// Single dispatch point for incoming deep links — mirrors Android's
/// MainActivity.handleIncomingUri. Two entry forms reach here:
///   - custom scheme  musicassistant://auth/callback   → OAuth (peeled off)
///   - custom scheme  musicassistant://app/<page>       → DeepLinkBus
///   - Universal Link https://…music-assistant.io/app/<page> → DeepLinkBus
/// The OAuth callback is handled explicitly; everything else is forwarded to
/// the shared DeepLinkBus, which self-filters and ignores anything it doesn't
/// recognize.
func handleIncomingURL(_ url: URL) {
    if url.scheme == "musicassistant", url.host == "auth" {
        guard url.path == "/callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return }
        KmpHelper.shared.authManager.handleOAuthCallback(token: code)
        return
    }
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
    private let subsystem = Bundle.main.bundleIdentifier ?? "io.music-assistant.client"

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

        // Makes `mawebrtc://` artwork URLs resolvable through the standard URL
        // loading system (and therefore AsyncImage/URLSession). Must follow
        // bootstrapKmp() — loads dispatch into Koin-resolved Kotlin.
        MAWebRTCURLProtocol.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // OAuthHandler presents `ASWebAuthenticationSession`;
                    // requires a live scene, so can't move to `init()`.
                    KmpHelper.shared.authManager.oauthHandler = OAuthHandler()

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
            case .active: KmpHelper.shared.onAppForeground()
            case .background: KmpHelper.shared.onAppBackground()
            case .inactive: break
            @unknown default: break
            }
        }
    }
}
