import Foundation
import Network
import os

/// Provokes iOS's local-network permission prompt before anything depends on the answer.
///
/// iOS shows that prompt the first time an app actually touches the local network, and denies
/// the access that triggered it while the user decides. This app's first such access was the
/// connect attempt itself, so on a fresh install the first "Connect" always failed even when
/// the host and port were right — the prompt appeared, the attempt underneath it died, and the
/// user had to grant and then tap Connect again.
///
/// There is no API to query the permission's state or to request it directly (still true on
/// iOS 26), so the only way to resolve it early is to perform some local-network operation
/// whose failure doesn't matter. Starting a Bonjour browse does exactly that: the prompt
/// appears while the connection form is on screen, and by the time anyone taps Connect the
/// answer is already recorded.
///
/// The browse results are deliberately ignored — server discovery isn't implemented, and this
/// type exists purely for the side effect. `Info.plist` must declare the browsed type under
/// `NSBonjourServices` or iOS rejects the browse outright (it would then fail without ever
/// showing the prompt, which is the one failure mode worth watching for in the log below).
@MainActor
final class LocalNetworkPermissionPrimer {

    /// The service type Music Assistant servers advertise. Nothing here depends on a match:
    /// an unanswered browse primes the permission just as well as an answered one. It's the
    /// honest choice of type, and it's what a real discovery feature would reuse.
    private static let serviceType = "_mass._tcp"

    /// Long enough for the system to raise the prompt, short enough that no browser lingers
    /// behind a form the user has stopped looking at.
    private static let probeDuration = Duration.seconds(3)

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jofreund.taktgeber",
        category: "LocalNetworkPermission"
    )

    private var browser: NWBrowser?

    /// Idempotent, and harmless once permission has already been granted or denied — in that
    /// case the browse simply runs and finds nothing, with no prompt and nothing on screen.
    func prime() {
        guard browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [log] state in
            if case .failed(let error) = state {
                // Most likely cause: NSBonjourServices doesn't declare `serviceType`, in which
                // case the permission prompt never appears and first-connect breaks again.
                log.error("local-network probe failed: \(String(describing: error), privacy: .public)")
            }
        }
        self.browser = browser
        browser.start(queue: .main)

        Task { [weak self] in
            try? await Task.sleep(for: Self.probeDuration)
            self?.cancel()
        }
    }

    func cancel() {
        browser?.cancel()
        browser = nil
    }
}
