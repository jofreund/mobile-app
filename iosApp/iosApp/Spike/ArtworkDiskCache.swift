import UIKit

/// On-disk store for already-downsampled artwork, behind `SpikeImageLoader`'s memory cache.
///
/// The memory cache dies with the process, so without this every cold launch re-downloads every
/// image the user scrolls past. That matters most over WebRTC, where artwork is relayed through a
/// single data channel — slow enough that the Compose client carried a 256 MB Coil `DiskCache`
/// specifically to avoid it, noting the URLs are stable enough for a near-100% hit rate on
/// revisited screens. That cache went away with Coil; this replaces it.
///
/// Stores what was decoded, not what was downloaded: entries are already scaled to the size they
/// will be drawn at, so a hit skips both the network *and* the resize.
///
/// Nothing here is on the main actor and nothing is async — callers are expected to be off the
/// main thread already (`SpikeImageLoader` is an actor). Failures are silent by design: a cache
/// that throws is worse than one that misses.
struct ArtworkDiskCache {

    static let shared = ArtworkDiskCache()

    private let budgetBytes: UInt64
    private let directory: URL

    /// - Parameters:
    ///   - directory: defaults to Caches — not Application Support, because this is all
    ///     re-derivable from the server, so it should be evictable under storage pressure and
    ///     excluded from backup. Both come free there. Tests pass a temporary directory.
    ///   - budgetBytes: defaults to the budget Coil was configured with.
    init(directory: URL? = nil, budgetBytes: UInt64 = 256 * 1024 * 1024) {
        self.budgetBytes = budgetBytes
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Read / write

    func image(forKey key: String) -> UIImage? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touch it so the trim pass treats recently-read entries as recently-used, not just
        // recently-written — otherwise a long-lived favourite is evicted for being old.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return UIImage(data: data)
    }

    func store(_ image: UIImage, forKey key: String) {
        guard let data = encode(image) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    /// PNG only when the image actually needs alpha. Artwork is overwhelmingly opaque album art,
    /// where JPEG is several times smaller for the same result — but SVG-rendered artwork (genre
    /// tiles) is transparent, and flattening it would put black boxes in the grid.
    private func encode(_ image: UIImage) -> Data? {
        let alpha = image.cgImage?.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last
            || alpha == .premultipliedFirst || alpha == .premultipliedLast
        return hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.85)
    }

    /// Hashed rather than escaped: cache keys embed a full URL, which can exceed the filesystem's
    /// name limit and contains separators. Collisions would serve the wrong artwork, so this uses
    /// the full 64-bit hash rather than a truncation.
    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(String(format: "%016llx", stableHash(key)))
    }

    /// FNV-1a. `String.hashValue` is seeded per-process, so entries written by one launch would
    /// never be found by the next — which is the entire point of a disk cache.
    private func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - Eviction

    /// Drops least-recently-used entries until the directory is back under budget. Cheap when
    /// there's nothing to do — one directory listing — so callers can run it opportunistically
    /// rather than scheduling it.
    func trimIfNeeded() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        var sized: [(url: URL, date: Date, size: UInt64)] = []
        var total: UInt64 = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.totalFileAllocatedSize
            else { continue }
            let date = values.contentModificationDate ?? .distantPast
            sized.append((url, date, UInt64(size)))
            total += UInt64(size)
        }
        guard total > budgetBytes else { return }

        // Oldest first, deleting until comfortably under — trimming to exactly the budget would
        // make the next write trip the pass again.
        let target = budgetBytes * 8 / 10
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Wipes everything. The server can reuse an artwork URL for changed bytes, so a cache that
    /// can't be cleared eventually shows something stale with no way back.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
