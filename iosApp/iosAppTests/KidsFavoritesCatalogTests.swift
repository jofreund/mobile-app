import XCTest

/// The pure half of kids mode: what feeds the carousel, how a load is judged, and the gate.
final class KidsFavoritesCatalogTests: XCTestCase {

    // MARK: - Media type selection

    func testDefaultSelectionIsAlbumsPlaylistsAudiobooks() {
        XCTAssertEqual(KidsMediaType.defaultSelection, [.album, .playlist, .audiobook])
    }

    func testEncodeDecodeRoundTripsInOrder() {
        let types: [KidsMediaType] = [.radio, .album, .track]
        XCTAssertEqual(KidsMediaType.encode(types), "radio,album,track")
        XCTAssertEqual(KidsMediaType.decode("radio,album,track"), types)
    }

    func testDecodeFallsBackForMissingOrMeaninglessValues() {
        XCTAssertNil(KidsMediaType.decode(nil))
        XCTAssertNil(KidsMediaType.decode(""))
        XCTAssertNil(KidsMediaType.decode("artist,genre"))
    }

    func testDecodeDropsUnknownNamesButKeepsTheRest() {
        XCTAssertEqual(KidsMediaType.decode("album,artist,podcast"), [.album, .podcast])
    }

    func testTogglingOnNormalisesToDeclarationOrder() {
        XCTAssertEqual(
            KidsMediaType.toggling(.album, on: true, in: [.radio, .playlist]),
            [.album, .playlist, .radio]
        )
    }

    func testTogglingOffRemovesTheType() {
        XCTAssertEqual(KidsMediaType.toggling(.playlist, on: false, in: [.album, .playlist]), [.album])
    }

    func testTogglingOffTheLastTypeKeepsIt() {
        XCTAssertEqual(KidsMediaType.toggling(.album, on: false, in: [.album]), [.album])
    }

    // MARK: - Merging

    func testMergeKeepsSectionOrderAndDropsDuplicateIds() {
        let merged = KidsFavoritesCatalog.merge([["a", "b"], ["b", "c"], ["a"]], id: { $0 })
        XCTAssertEqual(merged, ["a", "b", "c"])
    }

    // MARK: - Load outcome (the nil-vs-empty rule)

    func testATimedOutSectionFailsTheLoad() {
        let outcome = KidsFavoritesCatalog.outcome(sections: [["a"], nil], isReady: true, id: { $0 })
        XCTAssertEqual(outcome, .failed)
    }

    func testAllEmptyWhileNotReadyIsAFailureNotAnEmptyLibrary() {
        let outcome = KidsFavoritesCatalog.outcome(sections: [[], []], isReady: false, id: { (s: String) in s })
        XCTAssertEqual(outcome, .failed)
    }

    func testAllEmptyWhileReadyIsGenuinelyEmpty() {
        let outcome = KidsFavoritesCatalog.outcome(sections: [[], []], isReady: true, id: { (s: String) in s })
        XCTAssertEqual(outcome, .loaded([]))
    }

    func testContentWhileNotReadyStillLoads() {
        // Readiness only disambiguates an empty answer; a server that returned items answered.
        let outcome = KidsFavoritesCatalog.outcome(sections: [["a"], []], isReady: false, id: { $0 })
        XCTAssertEqual(outcome, .loaded(["a"]))
    }

    // MARK: - Parent gate

    func testChallengeUsesTwoDigitOperands() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let challenge = ParentGateChallenge.random(using: &generator)
            XCTAssertTrue((12...39).contains(challenge.left), "\(challenge.left)")
            XCTAssertTrue((13...48).contains(challenge.right), "\(challenge.right)")
            XCTAssertEqual(challenge.answer, challenge.left + challenge.right)
        }
    }

    func testAcceptsTheSumWithSurroundingWhitespace() {
        let challenge = ParentGateChallenge(left: 17, right: 25)
        XCTAssertTrue(challenge.accepts("42"))
        XCTAssertTrue(challenge.accepts(" 42\n"))
    }

    func testRejectsWrongOrNonNumericAnswers() {
        let challenge = ParentGateChallenge(left: 17, right: 25)
        XCTAssertFalse(challenge.accepts("41"))
        XCTAssertFalse(challenge.accepts(""))
        XCTAssertFalse(challenge.accepts("forty-two"))
    }
}

/// A tiny deterministic generator, so the range test is repeatable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
