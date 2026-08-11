import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MusicAssistantKit

/// Outside the actor deliberately. `NSCache` is thread-safe on its own, and holding it here is
/// what lets `ArtworkLoader.cachedImage` answer synchronously — an actor-isolated cache can
/// only be read with `await`, which costs a frame even on a hit, and that frame is a placeholder.
private let artworkCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    // Both limits, because neither alone is safe. A count limit says nothing about size: 400
    // entries is a few megabytes of 36pt mini-player thumbnails but well over a gigabyte of
    // 340pt player artwork at 3x, which is a jetsam, not a cache. A cost limit alone would
    // happily hold tens of thousands of tiny entries. `NSCache` evicts under memory pressure on
    // its own; these keep it from getting there in the first place.
    cache.countLimit = 400
    cache.totalCostLimit = 96 * 1024 * 1024
    return cache
}()

private extension UIImage {
    /// Resident bitmap size, for `NSCache` cost accounting. `UIImage` reports point dimensions;
    /// what actually occupies memory is the backing bitmap.
    var bitmapByteCost: Int {
        guard let bitmap = cgImage else { return 0 }
        return bitmap.bytesPerRow * bitmap.height
    }
}

/// Downsampling image loader for every screen's artwork — ItemDetails, Artist, Genre, Library,
/// Browse and the player all go through this.
///
/// Three tiers: an in-memory `NSCache`, then `ArtworkDiskCache`, then the network. The decode is
/// the reason it exists at all — bare `AsyncImage` keeps the full-resolution bitmap resident per
/// cell, which is what makes a grid of 60pt thumbnails backed by 1000px JPEGs stutter.
///
/// Deliberately dependency-free. Every request goes through `URLSession`, so
/// `MAWebRTCURLProtocol` transparently handles `mawebrtc://` and this code never has to know
/// which transport it is on.
actor ArtworkLoader {

    static let shared = ArtworkLoader()

    /// A cached image, or nil — without suspending. Callers use this to render a hit on their
    /// very first frame instead of flashing a placeholder and fading in behind an `await`.
    nonisolated static func cachedImage(for url: URL, maxPixel: CGFloat) -> UIImage? {
        artworkCache.object(forKey: cacheKey(url, maxPixel) as NSString)
    }

    private nonisolated static func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> String {
        ArtworkCacheKey.memoryKey(url: url, maxPixel: maxPixel)
    }

    /// In-flight loads, so a grid scrolling over the same URL twice does one fetch — and so a
    /// load is cancelled once no cell is waiting on it. See `SharedLoadRegistry`.
    private var inFlight = SharedLoadRegistry<Task<UIImage?, Never>>()

    /// Resolved once, on the first decode, and kept — see `resolveDisplayScale`.
    private var displayScale: CGFloat?

    /// The scale to decode at, in pixels per point.
    ///
    /// `UIScreen.main` used to supply this, but it is deprecated *and* main-actor-isolated, while
    /// the decode path is deliberately nonisolated — it runs off the main thread once per cell.
    /// So the value is fetched through the window scene (the replacement Apple points at) on one
    /// main-actor hop and cached on the actor. It doesn't change under this app: there is no
    /// external-display or multi-window support to move a view to a screen of a different scale.
    ///
    /// Note this deliberately does not enter the cache key, which stays in points. Scale is a
    /// property of the device, not of the request, so folding it in would only make the key
    /// longer.
    private func resolveDisplayScale() async -> CGFloat {
        if let displayScale { return displayScale }
        let resolved = await MainActor.run {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.scale ?? UITraitCollection.current.displayScale
        }
        displayScale = resolved
        return resolved
    }

    /// Loads artwork, sharing one fetch between every caller that wants the same image.
    ///
    /// Cancelling the calling task — which SwiftUI does when a cell scrolls away or its URL
    /// changes — withdraws that caller. The underlying fetch is cancelled only when the last
    /// waiter withdraws, so an off-screen cell disappearing never takes a visible cell's image
    /// with it.
    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = Self.cacheKey(url, maxPixel)

        if let cached = artworkCache.object(forKey: key as NSString) { return cached }

        // Resolved before joining, deliberately: `join` and `start` must not be separated by a
        // suspension or two callers can both be told to start. This is the only `await` on that
        // path, and after the first call it is a cached read.
        let scale = await resolveDisplayScale()

        let task: Task<UIImage?, Never>
        let token: SharedLoadRegistry<Task<UIImage?, Never>>.Token
        if let running = inFlight.join(key) {
            (task, token) = running
        } else {
            // Server scope resolved here rather than in `cacheKey`: this is the actor, so it is
            // off the main thread and runs once per real load, whereas the memory key is computed
            // per cell in `ArtworkView.init`. `ArtworkCacheKey.diskKey` explains why the disk
            // needs the scope and memory doesn't.
            let diskKey = ArtworkCacheKey.diskKey(
                url: url,
                maxPixel: maxPixel,
                serverScope: KmpHelper.shared.getServerId()
            )
            task = Self.load(url: url, diskKey: diskKey, maxPixel: maxPixel, scale: scale)
            token = inFlight.start(key, handle: task)
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // Hops back onto the actor: `onCancel` runs on whichever thread cancelled us.
            Task { await self.withdraw(key) }
        }

        // Only the uncancelled path reports completion. When we were cancelled, `withdraw` has
        // already done the bookkeeping — and it knows whether anyone else is still waiting, which
        // this does not: finishing here would evict an entry those other waiters still need.
        if !Task.isCancelled {
            inFlight.finish(key, token: token)
        }
        if let image {
            artworkCache.setObject(image, forKey: key as NSString, cost: image.bitmapByteCost)
        }
        return image
    }

    /// A caller lost interest. Cancels the shared fetch only if nobody else is waiting on it.
    private func withdraw(_ key: String) {
        inFlight.withdraw(key)?.cancel()
    }

    private nonisolated static func load(
        url: URL,
        diskKey: String,
        maxPixel: CGFloat,
        scale: CGFloat
    ) -> Task<UIImage?, Never> {
        Task<UIImage?, Never> {
            // Disk before network. Entries are stored already downsampled, so a hit skips the
            // resize as well as the round trip — and over WebRTC the round trip is the expensive
            // part. See `ArtworkDiskCache`.
            if let onDisk = ArtworkDiskCache.shared.image(forKey: diskKey, scale: scale) {
                return onDisk
            }

            // Two attempts, because the usual failure here is not "no artwork" but a transport
            // that went away mid-request: a WebRTC reconnect runs `WebRTCHttpProxy.cancelAll()`,
            // which fails every in-flight fetch at once. Nothing would ask again — the cell keeps
            // its placeholder until something happens to rebuild the view — so the retry is the
            // only thing standing between a blip and a screen of grey squares. Bounded at two so
            // a genuinely unreachable URL costs one extra request rather than a loop, and only
            // for errors worth repeating (see `isWorthRetrying`); a decode failure returns nil
            // from the first attempt and never comes back here.
            for attempt in 0...1 {
                do {
                    return try await Self.fetchAndDecode(
                        url: url, diskKey: diskKey, maxPixel: maxPixel, scale: scale
                    )
                } catch {
                    guard attempt == 0, ArtworkRetryPolicy.isWorthRetrying(error) else {
                        // Cancellation is an expected outcome here, not a fault — a scroll can
                        // produce dozens — so it is not logged. Anything else is worth knowing
                        // about, since a missing image looks identical to an absent one.
                        if !ArtworkRetryPolicy.isCancellation(error) {
                            NativeLog.shared.warn(
                                tag: logTag,
                                message: "fetch failed for \(url.absoluteString): "
                                    + "\(error.localizedDescription)"
                            )
                        }
                        return nil
                    }
                    try? await Task.sleep(for: .seconds(1))
                    // `Task.sleep` returns immediately once cancelled, so without this the retry
                    // would fire anyway — the one case where cancelling costs an extra request.
                    if Task.isCancelled { return nil }
                }
            }
            return nil
        }
    }

    /// One attempt. Throws only for transport failures — a response that arrives but cannot be
    /// turned into an image returns nil, which is a permanent answer for this URL.
    private nonisolated static func fetchAndDecode(
        url: URL,
        diskKey: String,
        maxPixel: CGFloat,
        scale: CGFloat
    ) async throws -> UIImage? {
        let (data, response) = try await URLSession.shared.data(from: url)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")

        if let image = downsample(data, maxPixel: maxPixel, scale: scale) {
            persist(image, forKey: diskKey)
            return image
        }

        // ImageIO decodes no vector formats, and this server serves genre artwork as
        // `image/svg+xml`. Tried only after ImageIO declines, so raster artwork never
        // pays for the web view behind this. See `SVGRasterizer`.
        if SVGRasterizer.looksLikeSVG(data, contentType: contentType) {
            if let image = await SVGRasterizer.shared.image(from: data, maxPixel: maxPixel) {
                // Worth caching more than most: rasterizing one of these costs a web view.
                persist(image, forKey: diskKey)
                return image
            }
            NativeLog.shared.warn(
                tag: logTag,
                message: "SVG rasterization failed (\(data.count) bytes) for \(url.absoluteString)"
            )
            return nil
        }

        // Neither a format ImageIO knows nor an SVG. The content type and leading bytes
        // are logged because a decode failure is otherwise indistinguishable from "no
        // artwork" — the cell just shows its placeholder either way. That silence is
        // what hid the SVG case until the log said `type=image/svg+xml`.
        let head = String(decoding: data.prefix(48), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        NativeLog.shared.warn(
            tag: logTag,
            message: "decode failed (\(data.count) bytes, type=\(contentType ?? "?")) for "
                + "\(url.absoluteString) — starts: \(head)"
        )
        return nil
    }

    /// Writes off the actor: file IO inside it would block every other artwork request for the
    /// duration, and nothing waits on the result.
    private nonisolated static func persist(_ image: UIImage, forKey key: String) {
        Task.detached(priority: .utility) {
            ArtworkDiskCache.shared.store(image, forKey: key)
        }
    }

    private static let logTag = "ArtworkLoader"

    /// Decode straight to the size we will draw at. This is the whole point —
    /// `UIImage(data:)` would keep the full-resolution bitmap resident per cell.
    private nonisolated static func downsample(
        _ data: Data,
        maxPixel: CGFloat,
        scale: CGFloat
    ) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * scale,
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

/// How an artwork view claims space.
enum ArtworkSizing {
    /// Exact point size, for list rows and the detail header.
    case fixed(CGFloat)
    /// Fills the available width and stays square — required inside a
    /// `LazyVGrid`, whose column width is decided by the grid, not the cell.
    /// The associated value is only a decode hint.
    case flexible(decodeHint: CGFloat)

    /// Longest edge in points, for choosing the decode size and glyph scale.
    var referenceSize: CGFloat {
        switch self {
        case .fixed(let size): size
        case .flexible(let hint): hint
        }
    }
}

/// Artwork view with a type-appropriate placeholder and a cross-fade on arrival.
struct ArtworkView: View {

    let url: URL?
    let kind: MediaItem.Kind
    let sizing: ArtworkSizing

    /// Draws a hairline along the artwork's edge, so a tile whose cover fades to white (or to
    /// black) still reads as a tile rather than dissolving into the page.
    ///
    /// A flag rather than something the caller overlays itself, because only this view knows
    /// the shape being clipped to — circle or rounded rect, with a radius derived from the
    /// reference size. An outside overlay would have to restate that formula and would drift
    /// silently the moment it changed here.
    let showsBorder: Bool

    @State private var image: UIImage?

    @Environment(\.displayScale) private var displayScale

    init(url: URL?, kind: MediaItem.Kind, sizing: ArtworkSizing, showsBorder: Bool = false) {
        self.url = url
        self.kind = kind
        self.sizing = sizing
        self.showsBorder = showsBorder
        // Seeded from the cache so an image already in memory is on screen for the *first*
        // frame. Starting at nil and awaiting the loader meant every re-appearance — coming
        // back from a detail page, switching tabs — flashed the placeholder and cross-faded,
        // even though the bytes were right there. On a screen of tiles that reads as the whole
        // page flickering, and it is why this looked like a data reload.
        _image = State(
            initialValue: url.flatMap {
                ArtworkLoader.cachedImage(for: $0, maxPixel: sizing.referenceSize)
            }
        )
    }

    private var reference: CGFloat { sizing.referenceSize }

    /// Corner radii stop growing at 16pt.
    ///
    /// 11% of the edge is right for tiles and rows — 4pt at 36, 15pt at 140 — but it does not
    /// keep being right as things get bigger. The expanded player's hero asks for a 340pt
    /// reference, which came out at 37pt and ate visible corners of the cover.
    ///
    /// 16 rather than something derived: measured against Apple Music's now-playing artwork,
    /// which rounds at roughly 3% of its edge, a hero here would want about 10pt. This app is
    /// rounder than that everywhere else by design — its tiles sit at 11% — so matching the
    /// reference exactly at the hero alone would make the hero the odd one out. 16 lands between
    /// the two and is well clear of the corner-eating.
    ///
    /// Surfaces this moves: the player hero (37 → 16) and both detail headers (24 → 16 and
    /// 20 → 16). Tiles at 140 and below keep the proportional rule untouched.
    private static let maxCornerRadius: CGFloat = 16

    private var shape: AnyShape {
        kind.prefersCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(
                RoundedRectangle(
                    cornerRadius: min(reference * 0.11, Self.maxCornerRadius),
                    style: .continuous
                )
            )
    }

    var body: some View {
        content
            .clipShape(shape)
            .overlay {
                if showsBorder {
                    // `.separator` is the system's own hairline colour and already adapts to
                    // light and dark, so this stays subtle against either page background
                    // without a hand-tuned opacity. One physical pixel wide — a fixed 0.5 would
                    // be 1.5px on a 3x screen, which is a line, not a hairline.
                    shape.stroke(Color(uiColor: .separator), lineWidth: 1 / displayScale)
                }
            }
            .animation(.easeOut(duration: 0.18), value: image != nil)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                // Runs on a URL change too (cell reuse), where the seeded value above belongs
                // to the previous URL — so take the synchronous hit again before suspending.
                if let cached = ArtworkLoader.cachedImage(for: url, maxPixel: reference) {
                    image = cached
                    return
                }
                // Deliberately not guarded on a prior attempt: that would strand a cell whose
                // first attempt failed.
                let loaded = await ArtworkLoader.shared.image(for: url, maxPixel: reference)

                // Nothing is written back once cancelled. Cancellation means either the cell is
                // going away — in which case the write is pointless — or `url` changed, and there
                // the write is actively wrong: the replacement task has already seeded `image`
                // from the cache for the *new* URL, and this one would blank it.
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }

    @ViewBuilder
    private var content: some View {
        switch sizing {
        case .fixed(let size):
            base.frame(width: size, height: size)
        case .flexible:
            // aspectRatio(contentMode: .fit) on a square keeps the cell square at
            // whatever width the grid hands us.
            base.frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
        }
    }

    private var base: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: kind.symbol)
                            .font(.system(size: reference * 0.3))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
    }
}
