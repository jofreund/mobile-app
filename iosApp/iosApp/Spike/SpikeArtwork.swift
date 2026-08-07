import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ComposeApp

/// Downsampling image loader and cache for the spike.
///
/// Deliberately small and dependency-free. It exists to answer one question
/// honestly — *is artwork acceptable at scroll speed* — which bare `AsyncImage`
/// cannot: it has no usable memory cache and decodes at full resolution, so a
/// grid of 60pt thumbnails backed by 1000px JPEGs would stutter for reasons that
/// have nothing to do with the Kotlin bridge and would read as a false negative.
///
/// Phase D replaces this with Nuke (prefetching, disk cache, progressive decode).
/// The important part is already load-bearing here: every request goes through
/// `URLSession`, so `MAWebRTCURLProtocol` transparently handles `mawebrtc://`
/// and this code never has to know the difference.
actor SpikeImageLoader {

    static let shared = SpikeImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    /// In-flight loads, so a grid scrolling over the same URL twice does one fetch.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(maxPixel))"

        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<UIImage?, Never> {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = Self.downsample(data, maxPixel: maxPixel) else {
                    NativeLog.shared.warn(
                        tag: Self.logTag,
                        message: "decode failed (\(data.count) bytes) for \(url.absoluteString)"
                    )
                    return nil
                }
                return image
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
        if let image { cache.setObject(image, forKey: key as NSString) }
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
                guard let url else { return }
                // Re-entering with the same URL (cell reuse, scroll back) hits the
                // loader's cache, so there is no need to guard on a prior attempt —
                // and guarding would strand cells whose first attempt failed.
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
