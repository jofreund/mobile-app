import XCTest
import Foundation

// `ArtworkCacheKey.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

final class ArtworkCacheKeyTests: XCTestCase {

    private let webrtc = URL(string: "mawebrtc://proxy/imageproxy?path=/media/cover.jpg")!
    private let direct = URL(string: "http://homeassistant.local:8095/imageproxy?path=/media/cover.jpg")!

    /// The bug this exists for: every WebRTC artwork URL starts with the same constant base, so
    /// the same local path on two different servers is the same URL for two different images.
    func testWebRTCKeysAreScopedByServer() {
        let first = ArtworkCacheKey.diskKey(url: webrtc, maxPixel: 60, serverScope: "server-a")
        let second = ArtworkCacheKey.diskKey(url: webrtc, maxPixel: 60, serverScope: "server-b")

        XCTAssertNotEqual(first, second)
    }

    /// Direct URLs already name their server, so they must keep their unscoped key — otherwise
    /// this change would orphan every entry in an existing cache.
    func testDirectKeysIgnoreTheServerScope() {
        let unscoped = ArtworkCacheKey.diskKey(url: direct, maxPixel: 60, serverScope: nil)

        XCTAssertEqual(ArtworkCacheKey.diskKey(url: direct, maxPixel: 60, serverScope: "server-a"), unscoped)
        XCTAssertEqual(ArtworkCacheKey.diskKey(url: direct, maxPixel: 60, serverScope: "server-b"), unscoped)
        XCTAssertEqual(unscoped, "\(direct.absoluteString)|60")
    }

    /// Artwork requested before the handshake lands still has to be cacheable; it just shares the
    /// unscoped bucket until the id is known.
    func testWebRTCFallsBackToUnscopedWhenTheServerIsUnknown() {
        let unknown = ArtworkCacheKey.diskKey(url: webrtc, maxPixel: 60, serverScope: nil)
        let empty = ArtworkCacheKey.diskKey(url: webrtc, maxPixel: 60, serverScope: "")

        XCTAssertEqual(unknown, "\(webrtc.absoluteString)|60")
        XCTAssertEqual(empty, unknown)
    }

    /// The memory key is the disk key without the scope, and must stay free of any Kotlin call
    /// — it runs per cell on the main thread.
    func testMemoryKeyIgnoresTheServerEntirely() {
        XCTAssertEqual(
            ArtworkCacheKey.memoryKey(url: webrtc, maxPixel: 60),
            ArtworkCacheKey.diskKey(url: webrtc, maxPixel: 60, serverScope: nil)
        )
        XCTAssertNotEqual(
            ArtworkCacheKey.memoryKey(url: webrtc, maxPixel: 60),
            ArtworkCacheKey.diskKey(url: webrtc, maxPixel: 60, serverScope: "server-a")
        )
    }

    /// The two sizes of one image are different bitmaps and must not collide.
    func testDecodeSizeSeparatesKeys() {
        XCTAssertNotEqual(
            ArtworkCacheKey.diskKey(url: direct, maxPixel: 60, serverScope: nil),
            ArtworkCacheKey.diskKey(url: direct, maxPixel: 340, serverScope: nil)
        )
    }

    /// Fractional point sizes round to the same bucket — a 59.5pt and a 60pt request should share
    /// one entry rather than fetching twice.
    func testFractionalSizesCollapse() {
        XCTAssertEqual(
            ArtworkCacheKey.diskKey(url: direct, maxPixel: 60.4, serverScope: nil),
            ArtworkCacheKey.diskKey(url: direct, maxPixel: 60.9, serverScope: nil)
        )
    }
}
