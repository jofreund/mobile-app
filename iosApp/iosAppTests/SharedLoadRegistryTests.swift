import XCTest

// `SharedLoadRegistry.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

/// `Handle` is a `Task` in the app; here it is an `Int`, which is the point of the type being
/// generic — the counting is what has to be right, and none of it needs concurrency to exercise.
final class SharedLoadRegistryTests: XCTestCase {

    private var registry = SharedLoadRegistry<Int>()

    // MARK: - Sharing

    func testFirstCallerIsToldToStart() {
        XCTAssertNil(registry.join("a"))
    }

    func testSecondCallerJoinsTheRunningLoad() {
        _ = registry.start("a", handle: 1)

        let joined = registry.join("a")

        XCTAssertEqual(joined?.handle, 1)
        XCTAssertEqual(registry.waiters(for: "a"), 2)
    }

    func testDifferentKeysAreIndependent() {
        _ = registry.start("a", handle: 1)

        XCTAssertNil(registry.join("b"))
        XCTAssertEqual(registry.waiters(for: "a"), 1)
    }

    // MARK: - Cancellation

    /// The whole point: an off-screen cell going away must not cancel the fetch a visible cell is
    /// still waiting on.
    func testWithdrawingWhileOthersWaitDoesNotCancel() {
        _ = registry.start("a", handle: 1)
        _ = registry.join("a")

        XCTAssertNil(registry.withdraw("a"), "should not hand back a handle to cancel")
        XCTAssertEqual(registry.waiters(for: "a"), 1)
    }

    func testLastWithdrawalCancels() {
        _ = registry.start("a", handle: 1)
        _ = registry.join("a")

        XCTAssertNil(registry.withdraw("a"))
        XCTAssertEqual(registry.withdraw("a"), 1, "the last withdrawal returns the handle")
        XCTAssertEqual(registry.activeCount, 0)
    }

    func testWithdrawingAnUnknownKeyIsHarmless() {
        XCTAssertNil(registry.withdraw("nothing"))
        XCTAssertEqual(registry.activeCount, 0)
    }

    /// After everyone withdraws, the key is clear and the next caller starts fresh rather than
    /// joining a cancelled load.
    func testKeyIsReusableAfterCancellation() {
        _ = registry.start("a", handle: 1)
        _ = registry.withdraw("a")

        XCTAssertNil(registry.join("a"), "next caller must be told to start, not handed a corpse")
    }

    // MARK: - Completion

    func testFinishClearsTheEntry() {
        let token = registry.start("a", handle: 1)

        registry.finish("a", token: token)

        XCTAssertEqual(registry.activeCount, 0)
        XCTAssertNil(registry.join("a"))
    }

    func testFinishIsIdempotent() {
        let token = registry.start("a", handle: 1)
        _ = registry.join("a")

        registry.finish("a", token: token)
        registry.finish("a", token: token)

        XCTAssertEqual(registry.activeCount, 0)
    }

    /// The reason tokens exist. A caller whose load was cancelled can come back late, after a
    /// second caller has started a *replacement* under the same key. Its completion must not
    /// evict that replacement, which would leave a live fetch untracked and let a third caller
    /// start a duplicate of it.
    func testLateFinishCannotEvictAReplacement() {
        let first = registry.start("a", handle: 1)
        _ = registry.withdraw("a")
        let second = registry.start("a", handle: 2)

        registry.finish("a", token: first)

        XCTAssertEqual(registry.activeCount, 1, "the replacement should still be tracked")
        XCTAssertEqual(registry.join("a")?.handle, 2)
        XCTAssertNotEqual(first, second)
    }

    func testTokensAreNotReused() {
        var seen: Set<SharedLoadRegistry<Int>.Token> = []
        for index in 0..<50 {
            let token = registry.start("k\(index)", handle: index)
            XCTAssertTrue(seen.insert(token).inserted, "token \(token) was handed out twice")
        }
    }

    // MARK: - Sequences

    /// A scroll: several cells want one image, most scroll away, one stays.
    func testOnlyTheSurvivorKeepsTheLoadAlive() {
        _ = registry.start("a", handle: 1)
        for _ in 0..<4 { _ = registry.join("a") }
        XCTAssertEqual(registry.waiters(for: "a"), 5)

        for _ in 0..<4 { XCTAssertNil(registry.withdraw("a")) }

        XCTAssertEqual(registry.waiters(for: "a"), 1)
        XCTAssertEqual(registry.activeCount, 1)
    }

    /// A caller that joined and then withdrew must not leave the count able to go negative and
    /// swallow a later genuine cancellation.
    func testCountCannotDriftBelowZero() {
        _ = registry.start("a", handle: 1)
        XCTAssertEqual(registry.withdraw("a"), 1)
        XCTAssertNil(registry.withdraw("a"))
        XCTAssertEqual(registry.waiters(for: "a"), 0)

        _ = registry.start("a", handle: 2)
        XCTAssertEqual(registry.withdraw("a"), 2, "a fresh load still cancels on its last waiter")
    }
}
