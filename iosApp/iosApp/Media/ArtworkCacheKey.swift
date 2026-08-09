import Foundation

/// Builds the keys that identify one cached artwork bitmap.
///
/// Pulled out of `ArtworkLoader` so it can be tested, and because getting it wrong is silent in
/// both directions: too coarse and the cache serves the wrong picture, too fine and it never hits
/// at all. Deliberately free of Kotlin types so it compiles into the test target as well.
///
/// There are two keys, and the difference is the point of this type.
enum ArtworkCacheKey {

    /// The scheme `MAWebRTCURLProtocol` claims. Lives here rather than on that class because this
    /// file is the one both targets can see.
    static let webrtcScheme = "mawebrtc"

    /// Key for the in-memory cache.
    ///
    /// Pure and cheap on purpose: this runs in `ArtworkView.init`, once per cell, on the main
    /// thread, every time a parent body re-runs. Nothing here may touch the Kotlin bridge — a
    /// string crossing that boundary is an allocation, and this is the wrong place to pay for one.
    ///
    /// - Parameter maxPixel: the decode size in points. Part of the key because the 60pt row
    ///   thumbnail and the 340pt player artwork for one URL are genuinely different bitmaps.
    static func memoryKey(url: URL, maxPixel: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(maxPixel))"
    }

    /// Key for the on-disk cache: the memory key plus the server, for URLs that need it.
    ///
    /// Artwork URLs are not always server-unique. Direct-mode URLs contain host and port, so they
    /// already name one. WebRTC URLs do not — they all begin `mawebrtc://proxy`, a compile-time
    /// constant — so two servers that each hold `/media/music/…/cover.jpg` mint byte-identical
    /// URLs for different images.
    ///
    /// Only the disk cache pays for this. In memory the collision needs the user to switch
    /// servers without relaunching, and it clears itself when they do relaunch; on disk it would
    /// outlive the launch, which is what makes it worth a Kotlin call. That call happens once per
    /// actual load, off the main thread — see `memoryKey` for why that distinction matters.
    ///
    /// Scoping only the ambiguous half also means direct-mode entries — the common case — keep
    /// their existing filenames instead of being orphaned by a key-format change.
    ///
    /// - Parameter serverScope: the connected server's id, or nil if the handshake hasn't landed.
    static func diskKey(url: URL, maxPixel: CGFloat, serverScope: String?) -> String {
        let base = memoryKey(url: url, maxPixel: maxPixel)
        guard url.scheme == webrtcScheme,
              let serverScope,
              !serverScope.isEmpty
        else { return base }
        return "\(base)|\(serverScope)"
    }
}
