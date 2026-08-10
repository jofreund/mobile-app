import Foundation

/// Reference-counts the callers waiting on a shared load, so it can be cancelled when — and only
/// when — the last of them goes away.
///
/// `ArtworkLoader` already deduplicates concurrent requests: a grid scrolling over the same URL
/// twice does one fetch. Cancellation is what makes that hard. A cell that scrolls off should
/// stop its download, but the download may be the one a *visible* cell is also waiting on, and
/// both failure modes are real:
///
/// - Never cancel, and a fast scroll leaves dozens of dead requests queued ahead of the visible
///   ones. Over WebRTC, where all artwork shares a single data channel, that is what makes images
///   crawl in behind a scroll.
/// - Cancel eagerly, and an invisible cell's disappearance takes an on-screen image with it.
///
/// Hence the counting — and hence it lives here, apart from the concurrency, where it can be
/// tested directly. `Handle` is whatever the owner needs back in order to cancel; `ArtworkLoader`
/// passes a `Task`.
///
/// Not thread-safe on its own: it is `mutating` throughout and expects to live inside an actor.
struct SharedLoadRegistry<Handle> {

    /// Distinguishes one load from its replacement under the same key.
    ///
    /// Without this, a caller whose load was cancelled could come back after a *later* caller had
    /// started a fresh load for the same key, and its completion bookkeeping would evict the new
    /// load from the registry — leaving it running but untracked, so the next caller would start
    /// a second copy of it.
    typealias Token = UInt64

    private struct Entry {
        let handle: Handle
        let token: Token
        var waiters: Int
    }

    private var entries: [String: Entry] = [:]
    private var nextToken: Token = 0

    /// How many loads are currently tracked. For tests and diagnostics.
    var activeCount: Int { entries.count }

    /// How many callers are waiting on `key`. For tests and diagnostics.
    func waiters(for key: String) -> Int { entries[key]?.waiters ?? 0 }

    /// Registers interest in `key`.
    ///
    /// Returns the handle of a load already running, which the caller should wait on instead of
    /// starting its own — plus the token to quote back to `finish`. Returns nil when nothing is
    /// running: the caller starts the work and registers it with `start(_:handle:)`.
    ///
    /// **`join` and `start` must not be separated by a suspension.** They are two calls rather
    /// than one closure-taking call because the owner needs to build the handle in between, and
    /// an `await` in that gap would let a second caller also be told to start.
    mutating func join(_ key: String) -> (handle: Handle, token: Token)? {
        guard var entry = entries[key] else { return nil }
        entry.waiters += 1
        entries[key] = entry
        return (entry.handle, entry.token)
    }

    /// Records the load that `join` asked the caller to start, with that caller as its first
    /// waiter. Returns the token identifying it.
    mutating func start(_ key: String, handle: Handle) -> Token {
        nextToken += 1
        entries[key] = Entry(handle: handle, token: nextToken, waiters: 1)
        return nextToken
    }

    /// One caller has lost interest — its view scrolled away or changed URL.
    ///
    /// Returns the handle to cancel when that was the last waiter, and nil while others remain.
    /// Returning the handle rather than cancelling here keeps this type free of any concurrency.
    mutating func withdraw(_ key: String) -> Handle? {
        guard var entry = entries[key] else { return nil }
        entry.waiters -= 1
        guard entry.waiters <= 0 else {
            entries[key] = entry
            return nil
        }
        entries.removeValue(forKey: key)
        return entry.handle
    }

    /// The load identified by `token` has finished on its own.
    ///
    /// Idempotent, and safe to call late: every waiter calls it, and a call quoting a stale token
    /// is ignored so a finished load cannot evict its own replacement.
    mutating func finish(_ key: String, token: Token) {
        guard entries[key]?.token == token else { return }
        entries.removeValue(forKey: key)
    }
}
