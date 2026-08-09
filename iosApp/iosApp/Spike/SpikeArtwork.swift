import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MusicAssistantKit

/// Downsampling image loader and cache — every native screen's artwork goes
/// through this (ItemDetails, Artist, Genre, Library, Browse), not just the
/// original Phase A spike it was built for.
///
/// Deliberately small and dependency-free: no usable memory cache and full-
/// resolution decode is what makes bare `AsyncImage` stutter in a grid of 60pt
/// thumbnails backed by 1000px JPEGs.
///
/// Phase D's plan called for replacing this with Nuke (prefetching, disk
/// cache, progressive decode) once artwork-at-scroll-speed needed more than
/// this provides — hasn't been revisited since, so this is still it. Every
/// request goes through `URLSession`, so `MAWebRTCURLProtocol` transparently
/// handles `mawebrtc://` and this code never has to know the difference.
/// Outside the actor deliberately. `NSCache` is thread-safe on its own, and holding it here is
/// what lets `SpikeImageLoader.cachedImage` answer synchronously — an actor-isolated cache can
/// only be read with `await`, which costs a frame even on a hit, and that frame is a placeholder.
private let artworkCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 400
    return cache
}()

actor SpikeImageLoader {

    static let shared = SpikeImageLoader()

    /// A cached image, or nil — without suspending. Callers use this to render a hit on their
    /// very first frame instead of flashing a placeholder and fading in behind an `await`.
    nonisolated static func cachedImage(for url: URL, maxPixel: CGFloat) -> UIImage? {
        artworkCache.object(forKey: cacheKey(url, maxPixel) as NSString)
    }

    private nonisolated static func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(maxPixel))"
    }

    /// In-flight loads, so a grid scrolling over the same URL twice does one fetch.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = Self.cacheKey(url, maxPixel)

        if let cached = artworkCache.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<UIImage?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")

                if let image = Self.downsample(data, maxPixel: maxPixel) { return image }

                // ImageIO decodes no vector formats, and this server serves genre artwork as
                // `image/svg+xml`. Tried only after ImageIO declines, so raster artwork never
                // pays for the web view behind this. See `SVGRasterizer`.
                if SVGRasterizer.looksLikeSVG(data, contentType: contentType) {
                    if let image = await SVGRasterizer.shared.image(from: data, maxPixel: maxPixel) {
                        return image
                    }
                    NativeLog.shared.warn(
                        tag: Self.logTag,
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
                    tag: Self.logTag,
                    message: "decode failed (\(data.count) bytes, type=\(contentType ?? "?")) for "
                        + "\(url.absoluteString) — starts: \(head)"
                )
                return nil
            } catch {
                NativeLog.shared.warn(
                    tag: Self.logTag,
                    message: "fetch failed for \(url.absoluteString): \(error.localizedDescription)"
                )
                return nil
            }
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if let image { artworkCache.setObject(image, forKey: key as NSString) }
        return image
    }

    private static let logTag = "SpikeImageLoader"

    /// Decode straight to the size we will draw at. This is the whole point —
    /// `UIImage(data:)` would keep the full-resolution bitmap resident per cell.
    private nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        let scale = UIScreen.main.scale
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
enum SpikeArtworkSizing {
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
struct SpikeArtwork: View {

    let url: URL?
    let kind: SpikeMediaItem.Kind
    let sizing: SpikeArtworkSizing

    @State private var image: UIImage?

    init(url: URL?, kind: SpikeMediaItem.Kind, sizing: SpikeArtworkSizing) {
        self.url = url
        self.kind = kind
        self.sizing = sizing
        // Seeded from the cache so an image already in memory is on screen for the *first*
        // frame. Starting at nil and awaiting the loader meant every re-appearance — coming
        // back from a detail page, switching tabs — flashed the placeholder and cross-faded,
        // even though the bytes were right there. On a screen of tiles that reads as the whole
        // page flickering, and it is why this looked like a data reload.
        _image = State(
            initialValue: url.flatMap {
                SpikeImageLoader.cachedImage(for: $0, maxPixel: sizing.referenceSize)
            }
        )
    }

    private var reference: CGFloat { sizing.referenceSize }

    private var shape: AnyShape {
        kind.prefersCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: reference * 0.11, style: .continuous))
    }

    var body: some View {
        content
            .clipShape(shape)
            .animation(.easeOut(duration: 0.18), value: image != nil)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                // Runs on a URL change too (cell reuse), where the seeded value above belongs
                // to the previous URL — so take the synchronous hit again before suspending.
                if let cached = SpikeImageLoader.cachedImage(for: url, maxPixel: reference) {
                    image = cached
                    return
                }
                // Deliberately not guarded on a prior attempt: that would strand a cell whose
                // first attempt failed.
                image = await SpikeImageLoader.shared.image(for: url, maxPixel: reference)
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
