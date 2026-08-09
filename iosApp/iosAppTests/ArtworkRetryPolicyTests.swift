import XCTest
import Foundation

// `ArtworkView.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

/// Covers the retry policy only. The fetch itself needs a live `URLSession` and, for the
/// `mawebrtc://` case, a connected Kotlin bridge — neither of which belongs in a unit test. What
/// is worth pinning is the decision: which failures earn a second attempt.
final class ArtworkRetryPolicyTests: XCTestCase {

    /// The case the retry exists for. A WebRTC reconnect runs `WebRTCHttpProxy.cancelAll()`,
    /// failing every in-flight request, and `MAWebRTCURLProtocol` surfaces that as this.
    func testTransportFailuresAreRetried() {
        for code: URLError.Code in [
            .cannotLoadFromNetwork, .networkConnectionLost, .notConnectedToInternet,
            .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .resourceUnavailable,
        ] {
            XCTAssertTrue(
                ArtworkRetryPolicy.isWorthRetrying(URLError(code)),
                "\(code) should be retried"
            )
        }
    }

    /// A second identical request would fail identically, so it is pure cost.
    func testPermanentFailuresAreNotRetried() {
        for code: URLError.Code in [.badURL, .unsupportedURL, .fileDoesNotExist, .cancelled] {
            XCTAssertFalse(
                ArtworkRetryPolicy.isWorthRetrying(URLError(code)),
                "\(code) should not be retried"
            )
        }
    }

    func testNonURLErrorsAreNotRetried() {
        struct Whatever: Error {}
        XCTAssertFalse(ArtworkRetryPolicy.isWorthRetrying(Whatever()))
        XCTAssertFalse(ArtworkRetryPolicy.isWorthRetrying(CocoaError(.fileReadUnknown)))
    }
}
