import Foundation
import MusicAssistantKit

/// Makes the synthetic `mawebrtc://` artwork scheme resolvable by the standard
/// URL loading system.
///
/// In WebRTC remote-access mode the server hands us image URLs that no network
/// stack can fetch — they only mean something to `WebRTCHttpProxy`, which tunnels
/// HTTP over the data channel. Until now every Swift image site had to know that
/// and call `KmpHelper.loadArtworkBytes` by hand (see `CarPlayImageLoader`).
///
/// Registering this protocol instead makes the scheme transparent to *anything*
/// built on `URLSession` — `AsyncImage`, a third-party image pipeline, and the
/// CarPlay/now-playing loaders alike. `startLoading()` is simply the right place
/// to call the Kotlin bridge from.
///
/// Register once, before any load, via ``registerOnce()``.
final class MAWebRTCURLProtocol: URLProtocol {

    /// One source of truth with `ArtworkCacheKey`, which has to recognise the same scheme to
    /// know when a URL needs server scoping.
    static let scheme = ArtworkCacheKey.webrtcScheme

    private static var registered = false

    /// Installs the protocol into the shared URL loading system. Idempotent.
    ///
    /// `URLProtocol.registerClass` covers `URLSession.shared` (and therefore
    /// `AsyncImage`). A session with a custom configuration needs the class in
    /// its own `protocolClasses` as well — see ``install(into:)``.
    static func registerOnce() {
        guard !registered else { return }
        registered = URLProtocol.registerClass(MAWebRTCURLProtocol.self)
        NativeLog.shared.info(
            tag: "MAWebRTCURLProtocol",
            message: registered ? "registered for \(scheme)://" : "registration FAILED"
        )
    }

    /// Prepends the protocol to a custom session configuration's handler chain.
    static func install(into configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        classes.insert(MAWebRTCURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    /// Live Kotlin subscription for the in-flight fetch, cancelled on `stopLoading()`.
    private var artworkLoad: MusicAssistantKit.Cancellable?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == scheme
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        artworkLoad = KmpHelper.shared.loadArtworkBytes(urlString: url.absoluteString) { [weak self] data in
            guard let self else { return }

            guard let bytes = data as Data?, !bytes.isEmpty else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
                return
            }

            // The proxy response carries a content-type that the Kotlin bridge does not
            // surface yet, so we infer it from the bytes. Provider icons are frequently
            // SVG, which image decoders will not sniff correctly without the hint.
            let response = URLResponse(
                url: url,
                mimeType: Self.inferMimeType(from: bytes),
                expectedContentLength: bytes.count,
                textEncodingName: nil
            )

            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: bytes)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        artworkLoad?.cancel()
        artworkLoad = nil
    }

    /// Minimal magic-number sniffing. Replaced in Phase D by the real `content-type`
    /// once `loadArtworkBytes` returns it alongside the payload.
    private static func inferMimeType(from data: Data) -> String {
        let prefix = [UInt8](data.prefix(12))

        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if prefix.count >= 12,
           Array(prefix[0..<4]) == [0x52, 0x49, 0x46, 0x46],
           Array(prefix[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        // SVG is text; both a bare root element and an XML prolog are common.
        if let head = String(data: data.prefix(256), encoding: .utf8) {
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<svg") || trimmed.hasPrefix("<?xml") { return "image/svg+xml" }
        }
        return "application/octet-stream"
    }
}
