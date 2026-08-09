import Foundation

/// Which artwork fetch failures earn a second attempt.
///
/// Pulled out of `ArtworkLoader` so it can be tested: the loader itself needs a live `URLSession`
/// and, for `mawebrtc://`, a connected Kotlin bridge, but the decision here is pure and is the
/// part that would be wrong in a way nobody notices — a too-broad policy doubles the request
/// count on a dead server, a too-narrow one leaves a screen of grey squares after a reconnect.
///
/// Deliberately free of Kotlin types so it compiles into the test target as well as the app.
enum ArtworkRetryPolicy {

    /// Deliberately a small allowlist rather than "anything that threw". The case this exists for
    /// is the WebRTC data channel being torn down and reopened, which surfaces as
    /// `cannotLoadFromNetwork` from `MAWebRTCURLProtocol`; a 404 or a malformed URL will fail
    /// identically the second time and should not cost a second round trip.
    static func isWorthRetrying(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotLoadFromNetwork, .networkConnectionLost, .notConnectedToInternet,
             .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
