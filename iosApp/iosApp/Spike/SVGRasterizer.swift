import UIKit
import WebKit

/// Renders SVG artwork to a `UIImage`, because nothing on the platform will.
///
/// ImageIO — which `SpikeImageLoader.downsample` uses, and which backs `UIImage(data:)` — decodes
/// no vector formats at all. `CGImageSourceCreateWithData` even succeeds on SVG bytes; it's the
/// type and the thumbnail that come back nil, so the failure is silent and looks exactly like an
/// item having no artwork.
///
/// This is not hypothetical for this app. Music Assistant serves generated genre artwork as
/// `image/svg+xml`, straight through `/imageproxy/…?size=512` — the `size` parameter resizes
/// rasters and passes vectors through untouched, so there is no server-side way out. The Compose
/// client handled these with Coil's `SvgDecoder`, registered in `AppImageLoader.kt` and still
/// there; this is its native counterpart.
///
/// **WKWebView is a heavy way to decode an image, and that's deliberate.** The alternatives were
/// a third-party SVG parser (a dependency, in a project that just spent a phase removing them)
/// or leaving genre art blank. To keep the cost bounded:
///
/// - Only reached when ImageIO has already refused the bytes, so raster artwork never touches it.
/// - One shared web view, reused, rather than one per image.
/// - Serialized through a gate: a screen of genres would otherwise start twenty of these at once.
/// - Callers cache the result (`SpikeImageLoader`'s `NSCache`), so each URL pays once.
@MainActor
final class SVGRasterizer {

    static let shared = SVGRasterizer()

    private let gate = Gate()
    private var webView: WKWebView?
    private var loadDelegate: LoadDelegate?

    /// Cheap sniff for SVG. Checks the payload rather than trusting `Content-Type`, since the
    /// bytes are what actually has to parse — and a proxy is free to mislabel them.
    nonisolated static func looksLikeSVG(_ data: Data, contentType: String?) -> Bool {
        if contentType?.lowercased().contains("svg") == true { return true }
        // An SVG document may open with an XML declaration, a DOCTYPE, comments or whitespace
        // before `<svg`, so scan a window rather than matching a prefix.
        let head = data.prefix(1024)
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.contains("<svg")
    }

    /// Rasterizes `data` into a square image `maxPixel` points on a side, or nil if it doesn't
    /// render. Safe to call concurrently — calls queue up rather than piling on web views.
    func image(from data: Data, maxPixel: CGFloat) async -> UIImage? {
        guard let svg = String(data: data, encoding: .utf8) else { return nil }

        await gate.acquire()
        defer { gate.release() }

        let side = max(maxPixel, 1)
        let web = webView ?? makeWebView(side: side)
        web.frame = CGRect(x: 0, y: 0, width: side, height: side)

        // The SVG is inlined into a document that forces it to fill the frame: many SVGs carry
        // their own width/height, and without this they render at their intrinsic size in a
        // corner of the snapshot.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <style>
          html,body { margin:0; padding:0; background:transparent; width:100%; height:100%; }
          svg { display:block; width:100% !important; height:100% !important; }
        </style></head><body>\(svg)</body></html>
        """

        guard await load(html, in: web) else { return nil }

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: side, height: side)
        // Snapshot at screen scale so the result matches what ImageIO-decoded artwork provides.
        config.snapshotWidth = NSNumber(value: Double(side))

        return await withCheckedContinuation { continuation in
            web.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func makeWebView(side: CGFloat) -> WKWebView {
        let config = WKWebViewConfiguration()
        // No network, no JS: these documents are a local string and must not fetch anything.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: side, height: side), configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        webView = web
        return web
    }

    /// Loads `html` and resolves once the web view finishes (or fails). Bounded by a timeout so a
    /// pathological document can't hold the gate — and with it every later rasterization — shut.
    private func load(_ html: String, in web: WKWebView) async -> Bool {
        let delegate = LoadDelegate()
        loadDelegate = delegate
        web.navigationDelegate = delegate

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    delegate.onFinish = { continuation.resume(returning: $0) }
                    web.loadHTMLString(html, baseURL: nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        /// Fires once; `loadHTMLString` produces exactly one terminal navigation callback.
        var onFinish: ((Bool) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?(true)
            onFinish = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFinish?(false)
            onFinish = nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFinish?(false)
            onFinish = nil
        }
    }

    /// Minimal async mutex. One rasterization at a time through the shared web view.
    private final class Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        @MainActor
        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        @MainActor
        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}
