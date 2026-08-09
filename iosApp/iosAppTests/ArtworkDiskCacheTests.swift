import XCTest
import UIKit

// `ArtworkDiskCache.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

final class ArtworkDiskCacheTests: XCTestCase {

    private var directory: URL!
    private var cache: ArtworkDiskCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = ArtworkDiskCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func image(size: CGFloat, opaque: Bool, color: UIColor = .red) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = opaque
        format.scale = 1
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            color.setFill()
            // Half-filled when transparent, so the alpha channel carries real information and a
            // format that drops it produces a visibly different image.
            context.fill(opaque ? bounds : bounds.insetBy(dx: size / 4, dy: size / 4))
        }
    }

    private var fileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    // MARK: - Round trip

    func testStoredImageIsReadBack() {
        cache.store(image(size: 40, opaque: true), forKey: "a")

        let loaded = cache.image(forKey: "a")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.size, CGSize(width: 40, height: 40))
    }

    func testMissReturnsNil() {
        XCTAssertNil(cache.image(forKey: "never-written"))
    }

    /// The point of the whole type: a second `ArtworkDiskCache` over the same directory — which is
    /// what the next launch is — must find what this one wrote. A per-process hash would not.
    func testEntriesSurviveANewInstanceOverTheSameDirectory() {
        cache.store(image(size: 20, opaque: true), forKey: "shared-key")

        let reopened = ArtworkDiskCache(directory: directory)

        XCTAssertNotNil(reopened.image(forKey: "shared-key"))
    }

    // MARK: - Keys

    /// The key embeds the decode size, so the 60pt row thumbnail and the 300pt header of the same
    /// URL are different entries. Returning one for the other would serve a blurry header.
    func testKeysAreIsolated() {
        cache.store(image(size: 10, opaque: true), forKey: "https://x/art.jpg|60")
        cache.store(image(size: 80, opaque: true), forKey: "https://x/art.jpg|300")

        XCTAssertEqual(cache.image(forKey: "https://x/art.jpg|60")?.size.width, 10)
        XCTAssertEqual(cache.image(forKey: "https://x/art.jpg|300")?.size.width, 80)
    }

    /// Keys are full URLs: slashes, colons and query strings can't be allowed to become path
    /// components or to overflow the filesystem's name limit.
    func testKeysWithPathSeparatorsAndExcessiveLengthRoundTrip() {
        let key = "https://host:8095/imageproxy?path=" + String(repeating: "a/b", count: 200)

        cache.store(image(size: 12, opaque: true), forKey: key)

        XCTAssertNotNil(cache.image(forKey: key))
        XCTAssertEqual(fileCount, 1, "the key should map to one flat file, not a directory tree")
    }

    func testRewritingAKeyReplacesRatherThanAccumulates() {
        cache.store(image(size: 10, opaque: true), forKey: "k")
        cache.store(image(size: 30, opaque: true), forKey: "k")

        XCTAssertEqual(fileCount, 1)
        XCTAssertEqual(cache.image(forKey: "k")?.size.width, 30)
    }

    // MARK: - Alpha

    /// Genre artwork is rasterized from SVG and transparent. Encoding it as JPEG would flatten the
    /// transparent region onto black and put boxes behind the tiles.
    func testTransparencyIsPreserved() throws {
        cache.store(image(size: 40, opaque: false), forKey: "svg")

        let loaded = try XCTUnwrap(cache.image(forKey: "svg"))
        let alpha = try XCTUnwrap(loaded.cgImage?.alphaInfo)

        XCTAssertNotEqual(alpha, .none)
        XCTAssertNotEqual(alpha, .noneSkipFirst)
        XCTAssertNotEqual(alpha, .noneSkipLast)
    }

    // MARK: - Eviction

    func testTrimIsANoOpUnderBudget() {
        let roomy = ArtworkDiskCache(directory: directory, budgetBytes: 10 * 1024 * 1024)
        for index in 0..<5 { roomy.store(image(size: 40, opaque: true), forKey: "k\(index)") }

        roomy.trimIfNeeded()

        XCTAssertEqual(fileCount, 5)
    }

    func testTrimEvictsOldestFirstDownToBudget() throws {
        let total = try writeAgedEntries(count: 6)
        // Budget derived from what was actually written rather than a literal: the cache measures
        // allocated size, and the filesystem allocates a whole block per file, so a hardcoded
        // small budget puts even a single entry over and evicts everything.
        let tight = ArtworkDiskCache(directory: directory, budgetBytes: total / 2)

        tight.trimIfNeeded()

        XCTAssertNotNil(tight.image(forKey: "k5"), "the newest entry must survive")
        XCTAssertNil(tight.image(forKey: "k0"), "the oldest entry should go first")
    }

    /// Reads touch the file, so an entry that is old but still in use isn't the first to go.
    func testReadingAnEntryProtectsItFromTheNextTrim() throws {
        let total = try writeAgedEntries(count: 6)
        let tight = ArtworkDiskCache(directory: directory, budgetBytes: total / 2)

        _ = tight.image(forKey: "k0")
        tight.trimIfNeeded()

        XCTAssertNotNil(tight.image(forKey: "k0"), "the entry that was just read should survive")
    }

    /// Writes `k0…k(count-1)`, oldest first, and returns their total allocated size. Timestamps
    /// are set explicitly because the filesystem's resolution is coarse enough that same-instant
    /// writes would leave the eviction order arbitrary.
    @discardableResult
    private func writeAgedEntries(count: Int) throws -> UInt64 {
        for index in 0..<count {
            cache.store(image(size: 60, opaque: true, color: .blue), forKey: "k\(index)")
            try setModified(key: "k\(index)", to: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        )
        return files.reduce(UInt64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            return sum + UInt64(size)
        }
    }

    func testClearRemovesEverythingAndLeavesTheCacheUsable() {
        cache.store(image(size: 20, opaque: true), forKey: "a")

        cache.clear()

        XCTAssertNil(cache.image(forKey: "a"))
        XCTAssertEqual(fileCount, 0)

        cache.store(image(size: 20, opaque: true), forKey: "b")
        XCTAssertNotNil(cache.image(forKey: "b"), "clear must not leave the directory missing")
    }

    /// Backdates the entry written immediately before the call. `fileURL(for:)` is private, so
    /// the file is identified as the most recently modified one — true by construction, since
    /// callers store and then backdate one key at a time.
    private func setModified(key: String, to date: Date) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let newest = files.max { lhs, rhs in modified(lhs) < modified(rhs) }
        let path = try XCTUnwrap(newest?.path, "no file was written for \(key)")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
