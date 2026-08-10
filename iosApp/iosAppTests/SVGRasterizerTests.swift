import XCTest
import UIKit

/// Proves the SVG path actually produces pixels, rather than trusting that it does.
///
/// This exists because the bug it fixes was invisible: ImageIO returns nil for SVG, the cell
/// falls back to its placeholder, and that is pixel-identical to an item with no artwork. The
/// only reason it was ever found is that someone compared against the old Compose client.
final class SVGRasterizerTests: XCTestCase {

    /// Shaped like Music Assistant's genre artwork: an XML declaration and a DOCTYPE ahead of
    /// `<svg`, which is what the device log showed (`starts: <?xml version="1.0" standalone="no"?>
    /// <!DOCTYPE`). A prefix match on `<svg` would miss this.
    private let genreShapedSVG = """
    <?xml version="1.0" standalone="no"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
      <rect x="0" y="0" width="24" height="24" fill="#39A0FF"/>
    </svg>
    """

    // MARK: - Sniffing

    func testRecognisesSVGFromContentType() {
        XCTAssertTrue(
            SVGRasterizer.looksLikeSVG(Data("not xml at all".utf8), contentType: "image/svg+xml")
        )
    }

    func testRecognisesSVGBehindAnXMLDeclarationAndDoctype() {
        // The payload is checked rather than the header, so a proxy that mislabels or omits the
        // content type doesn't cost us the artwork.
        XCTAssertTrue(SVGRasterizer.looksLikeSVG(Data(genreShapedSVG.utf8), contentType: nil))
    }

    func testDoesNotClaimBinaryRasterDataIsSVG() {
        // PNG magic number. Must not be diverted into the web view.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertFalse(SVGRasterizer.looksLikeSVG(png, contentType: "image/png"))
    }

    func testDoesNotClaimArbitraryTextIsSVG() {
        XCTAssertFalse(
            SVGRasterizer.looksLikeSVG(Data("<html><body>nope</body></html>".utf8), contentType: "text/html")
        )
    }

    // MARK: - Rasterizing

    @MainActor
    func testRasterizesSVGToAnImageOfTheRequestedSize() async throws {
        let image = await SVGRasterizer.shared.image(from: Data(genreShapedSVG.utf8), maxPixel: 64)

        let raster = try XCTUnwrap(image, "SVG produced no image — the whole point of this path")
        XCTAssertEqual(raster.size.width, 64, accuracy: 1)
        XCTAssertEqual(raster.size.height, 64, accuracy: 1)
    }

    /// The SVG declares 24x24; the rendered result must fill the requested box rather than
    /// sitting at its intrinsic size in a corner. Checks the centre pixel carries the fill
    /// colour, which only holds if the scaling CSS took effect.
    @MainActor
    func testScalesTheDocumentToFillRatherThanRenderingAtIntrinsicSize() async throws {
        let image = await SVGRasterizer.shared.image(from: Data(genreShapedSVG.utf8), maxPixel: 64)
        let raster = try XCTUnwrap(image)
        let centre = try XCTUnwrap(Self.pixel(in: raster, atFraction: 0.9))

        // Blue-dominant, and not transparent — i.e. the rect was painted out to 90% across.
        XCTAssertGreaterThan(centre.alpha, 0.5, "corner-ish pixel is transparent; SVG did not scale up")
        XCTAssertGreaterThan(centre.blue, centre.red, "expected the #39A0FF fill")
    }

    /// Serialized access through one shared web view — concurrent callers (a grid of genres)
    /// must all get an image rather than trampling each other.
    @MainActor
    func testConcurrentRasterizationsAllSucceed() async throws {
        let data = Data(genreShapedSVG.utf8)

        // Warm the shared rasterizer before the real work. XCTest orders tests alphabetically,
        // so this one runs first and was the only test paying to create the `WKWebView` and
        // launch WebKit's helper processes — and it paid inside `load`'s 3-second bound, which
        // a busy machine can genuinely exceed. That made this the suite's one flaky test, in a
        // way that looked like a concurrency defect and wasn't.
        //
        // The bound stays 3 seconds: it exists to stop a pathological document holding the gate
        // shut for every later rasterization, and that is a property of the app worth keeping
        // honest. Cold start simply isn't what this test is about — the claim under test is
        // that concurrent callers serialize instead of trampling each other.
        _ = await SVGRasterizer.shared.image(from: data, maxPixel: 32)

        let images = await withTaskGroup(of: UIImage?.self) { group in
            for _ in 0..<4 {
                group.addTask { @MainActor in
                    await SVGRasterizer.shared.image(from: data, maxPixel: 32)
                }
            }
            var out: [UIImage?] = []
            for await image in group { out.append(image) }
            return out
        }

        XCTAssertEqual(images.count, 4)
        XCTAssertTrue(images.allSatisfy { $0 != nil }, "a concurrent caller came back empty")
    }

    @MainActor
    func testRejectsBytesThatArenNotText() async {
        let image = await SVGRasterizer.shared.image(from: Data([0xFF, 0xD8, 0xFF, 0xE0]), maxPixel: 32)
        XCTAssertNil(image)
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    }

    /// Samples one pixel at `fraction` along both axes.
    private static func pixel(in image: UIImage, atFraction fraction: CGFloat) -> Pixel? {
        guard let cgImage = image.cgImage else { return nil }
        let x = Int(CGFloat(cgImage.width) * fraction)
        let y = Int(CGFloat(cgImage.height) * fraction)

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return Pixel(
            red: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255,
            alpha: CGFloat(bytes[3]) / 255
        )
    }
}
