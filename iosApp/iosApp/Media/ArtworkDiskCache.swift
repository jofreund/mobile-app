import UIKit

/// On-disk store for already-downsampled artwork, behind `ArtworkLoader`'s memory cache.
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
/// main thread already (`ArtworkLoader` is an actor). Failures are silent by design: a cache
/// that throws is worse than one that misses.
struct ArtworkDiskCache {

    static let shared = ArtworkDiskCache()

    private let budgetBytes: UInt64
    private let maxAge: TimeInterval
    private let directory: URL
    private let trimGate: TrimGate

    /// - Parameters:
    ///   - directory: defaults to Caches — not Application Support, because this is all
    ///     re-derivable from the server, so it should be evictable under storage pressure and
    ///     excluded from backup. Both come free there. Tests pass a temporary directory.
    ///   - budgetBytes: defaults to the budget Coil was configured with.
    ///   - maxAge: how long an entry may be served before it is refetched. See `isExpired`.
    init(
        directory: URL? = nil,
        budgetBytes: UInt64 = 256 * 1024 * 1024,
        maxAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.budgetBytes = budgetBytes
        self.maxAge = maxAge
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("artwork", isDirectory: true)
        // An eighth of the budget between trims. See `TrimGate` for why there is a gate at all.
        self.trimGate = TrimGate(threshold: max(budgetBytes / 8, 1))
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Read / write

    /// - Parameter scale: the scale to reconstruct the image at. Stored files are bare pixels —
    ///   the scale an image was decoded with isn't recoverable from PNG or JPEG — so without this
    ///   a 3x thumbnail would come back claiming to be three times its real point size. Nothing
    ///   currently depends on that (every artwork view is `.resizable()` inside an explicit
    ///   frame), but a disk hit and a network hit landing in the same memory cache under the same
    ///   key should not disagree about what they are.
    func image(forKey key: String, scale: CGFloat = 1) -> UIImage? {
        let url = fileURL(for: key)
        guard !isExpired(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        touchIfStale(url)

        // Decoded here, on whatever background thread the caller is on. `UIImage(data:)` is lazy:
        // left alone it defers the decode to the first draw, which happens on the main thread
        // mid-scroll — precisely the hitch the downsampling path exists to avoid. The network
        // path already forces this via `kCGImageSourceShouldCacheImmediately`.
        guard let decoded = UIImage(data: data)?.preparingForDisplay(),
              let bitmap = decoded.cgImage
        else { return nil }
        return UIImage(cgImage: bitmap, scale: scale, orientation: .up)
    }

    func store(_ image: UIImage, forKey key: String) {
        guard let data = encode(image) else { return }
        guard (try? data.write(to: fileURL(for: key), options: .atomic)) != nil else { return }
        if trimGate.shouldTrim(afterWriting: data.count) {
            trimIfNeeded()
        }
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

    /// Whether an entry is too old to serve.
    ///
    /// Music Assistant builds artwork URLs with an empty `checksum=` parameter, so the URL for an
    /// album does not change when its cover does. That stability is what makes this cache worth
    /// having — but it also means a replaced cover would otherwise be masked forever, where
    /// before the disk cache existed the staleness ended at the next launch. An age cap puts a
    /// ceiling back on it without needing any invalidation signal from the server.
    ///
    /// Deliberately keyed on *creation*, not modification: `touchIfStale` moves the modification
    /// date to keep LRU honest, so an entry the user looks at often would never expire. Writing
    /// an entry again replaces the file and resets its creation date, which is the right
    /// behaviour — a refetched image is a new entry.
    private func isExpired(_ url: URL) -> Bool {
        guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        else { return false }
        return Date().timeIntervalSince(created) > maxAge
    }

    // MARK: - Eviction

    /// Eviction is LRU by modification date, so a read has to count as a use — otherwise a
    /// long-lived favourite is evicted for being old. But a write on every read is a syscall per
    /// cell per scroll, so entries touched recently are left alone. Day granularity is far finer
    /// than eviction needs and makes the common case free.
    private func touchIfStale(_ url: URL) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let modified, Date().timeIntervalSince(modified) > Self.touchInterval else { return }
        // Always `now`, never a backdate. APFS pulls a file's creation date backwards to match any
        // modification date set earlier than it, and `isExpired` reads that creation date — so a
        // backdating touch here would quietly age entries out.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static let touchInterval: TimeInterval = 24 * 60 * 60

    /// Drops least-recently-used entries until the directory is back under budget.
    ///
    /// Callers do not need to invoke this — `store` runs it on the schedule `TrimGate` sets. It
    /// stays visible for tests and for anywhere that wants an unconditional pass.
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
}

/// Decides when a trim is worth running.
///
/// A trim enumerates the whole directory and stats every file. Running one after each write made
/// a scroll through a large library quadratic — a thousand cached images meant a thousand
/// enumerations of a directory holding up to a thousand files. Instead writes accumulate and only
/// the one that crosses the threshold pays.
///
/// The cost is that the cache sits at up to `budget + threshold` rather than exactly `budget`.
/// That is the right trade for a cache in the Caches directory: the budget is a target the system
/// can already overrule by evicting the whole folder.
private final class TrimGate: @unchecked Sendable {

    private let threshold: UInt64
    private let lock = NSLock()
    private var pendingBytes: UInt64 = 0

    init(threshold: UInt64) {
        self.threshold = threshold
    }

    /// Records a write and reports whether the caller should trim now. Resets before returning
    /// true, so concurrent writers produce one trim between them rather than one each.
    func shouldTrim(afterWriting bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pendingBytes += UInt64(max(bytes, 0))
        guard pendingBytes >= threshold else { return false }
        pendingBytes = 0
        return true
    }
}
