import XCTest

/// Ports of Kotlin's `DeepLinkBusTest` and `OAuthCallbackTest`, which guarded the URL
/// contracts while parsing lived in the kernel. The `/players` id is what the Live Activity's
/// tap URL rides on; the OAuth scheme is what the in-app session waits for.
final class DeepLinksTests: XCTestCase {

    private func link(_ string: String) -> DeepLink? {
        DeepLinkParser.parse(URL(string: string)!)
    }

    // MARK: - Pages

    func testPlayersWithoutAnIdCarriesNoPlayer() {
        XCTAssertEqual(link("musicassistant://app/players"), .players(playerId: nil))
    }

    func testPlayersWithAnIdCarriesTheId() {
        XCTAssertEqual(link("musicassistant://app/players/ap12345678"), .players(playerId: "ap12345678"))
    }

    func testAPercentEncodedIdIsDecoded() {
        // Player ids are server-issued opaque strings; the widget percent-encodes them into
        // the path, so spaces (and any reserved characters) must round-trip.
        XCTAssertEqual(
            link("musicassistant://app/players/media_player.living%20room"),
            .players(playerId: "media_player.living room")
        )
    }

    func testTheUniversalLinkFormCarriesTheIdToo() {
        XCTAssertEqual(
            link("https://app.music-assistant.io/app/players/ap12345678"),
            .players(playerId: "ap12345678")
        )
    }

    func testHomeSearchAndTheBareAppLink() {
        XCTAssertEqual(link("musicassistant://app/home"), .home)
        XCTAssertEqual(link("musicassistant://app"), .home)
        XCTAssertEqual(link("https://music-assistant.io/app/"), .home)
        XCTAssertEqual(link("musicassistant://app/search"), .search)
    }

    func testLibraryRootAndEveryCategory() {
        XCTAssertEqual(link("musicassistant://app/library"), .library(category: nil))
        for category in LibraryLinkCategory.allCases {
            XCTAssertEqual(link("musicassistant://app/library/\(category.rawValue)"), .library(category: category))
        }
        XCTAssertEqual(LibraryLinkCategory.albums.serverValue, "album")
        XCTAssertEqual(LibraryLinkCategory.radios.serverValue, "radio")
    }

    func testAnUnknownCategoryRejectsTheWholeLink() {
        XCTAssertNil(link("musicassistant://app/library/videos"), "Must not silently land on the tab root")
    }

    func testUnrelatedUrlsAreNotLinks() {
        XCTAssertNil(link("musicassistant://auth/callback?code=abc"))
        XCTAssertNil(link("https://music-assistant.io/docs/app"))
        XCTAssertNil(link("musicassistant://app/settings"))
    }

    // MARK: - Queue

    @MainActor
    func testConsumeClearsTheMatchingDestination() {
        let queue = DeepLinkQueue()
        queue.handle(URL(string: "musicassistant://app/players/ap12345678")!)
        queue.consume(.players(playerId: "ap12345678"))
        XCTAssertNil(queue.pending)
    }

    @MainActor
    func testConsumeOfAStaleDestinationLeavesANewerOnePending() {
        let queue = DeepLinkQueue()
        queue.handle(URL(string: "musicassistant://app/players/first")!)
        queue.handle(URL(string: "musicassistant://app/players/second")!)
        queue.consume(.players(playerId: "first"))
        XCTAssertEqual(queue.pending, .players(playerId: "second"))
    }

    @MainActor
    func testANonLinkLeavesThePendingValueAlone() {
        let queue = DeepLinkQueue()
        queue.handle(URL(string: "musicassistant://app/search")!)
        queue.handle(URL(string: "musicassistant://auth/callback?code=x")!)
        XCTAssertEqual(queue.pending, .search)
    }

    // MARK: - OAuth callback

    func testTheReturnUrlIsBuiltFromTheScheme() {
        XCTAssertTrue(
            OAuthCallbackParser.returnURL.hasPrefix("\(OAuthCallbackParser.scheme)://"),
            "The session matches on the scheme alone; it must be the prefix of the URL the server redirects to"
        )
        XCTAssertEqual(OAuthCallbackParser.returnURL, "musicassistant://auth/callback")
    }

    func testTheSchemeMatchesTheOneRegisteredInInfoPlist() {
        // iOS only delivers the callback to this app because CFBundleURLSchemes lists it. Pin
        // the literal rather than deriving it.
        XCTAssertEqual(OAuthCallbackParser.scheme, "musicassistant")
    }

    func testACallbackCarryingACodeYieldsTheCode() {
        XCTAssertEqual(OAuthCallbackParser.parse("musicassistant://auth/callback?code=abc123"), .code("abc123"))
    }

    func testExtraQueryParametersDoNotHideTheCode() {
        XCTAssertEqual(OAuthCallbackParser.parse("musicassistant://auth/callback?state=xyz&code=abc123"), .code("abc123"))
    }

    func testAProviderErrorIsReportedInsteadOfDropped() {
        XCTAssertEqual(
            OAuthCallbackParser.parse("musicassistant://auth/callback?error=access_denied"),
            .failed(reason: "access_denied"),
            "Silently ignoring an error callback leaves the user on a spinner nothing can clear"
        )
    }

    func testErrorDescriptionIsPreferredOverTheErrorCode() {
        XCTAssertEqual(
            OAuthCallbackParser.parse("musicassistant://auth/callback?error=access_denied&error_description=User+said+no"),
            .failed(reason: "User said no")
        )
    }

    func testACallbackWithNeitherCodeNorErrorIsAFailureRatherThanACode() {
        guard case .failed = OAuthCallbackParser.parse("musicassistant://auth/callback") else {
            return XCTFail("expected .failed")
        }
    }

    func testAnEmptyCodeIsNotACode() {
        guard case .failed = OAuthCallbackParser.parse("musicassistant://auth/callback?code=") else {
            return XCTFail("expected .failed")
        }
    }

    func testATrailingSlashStillMatchesTheCallbackPath() {
        XCTAssertEqual(OAuthCallbackParser.parse("musicassistant://auth/callback/?code=abc123"), .code("abc123"))
    }

    func testAPageDeepLinkIsNotAnOAuthCallback() {
        XCTAssertEqual(OAuthCallbackParser.parse("musicassistant://app/library"), .notOAuth,
                       "A non-OAuth deep link must fall through to the deep-link queue untouched")
    }

    func testAUniversalLinkIsNotAnOAuthCallback() {
        XCTAssertEqual(OAuthCallbackParser.parse("https://music-assistant.io/app/library"), .notOAuth)
    }

    func testAForeignSchemeReachingOurCallbackPathIsNotOurs() {
        XCTAssertEqual(OAuthCallbackParser.parse("otherapp://auth/callback?code=abc123"), .notOAuth)
    }

    func testGarbageDoesNotThrow() {
        XCTAssertEqual(OAuthCallbackParser.parse("not a url at all"), .notOAuth)
        XCTAssertEqual(OAuthCallbackParser.parse(""), .notOAuth)
    }
}
