import XCTest

// `SearchSections.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

final class SearchSectionsTests: XCTestCase {

    private func group(_ id: String, _ items: [String]) -> SearchSection<String> {
        SearchSection(id: id, title: id.capitalized, items: items)
    }

    private func ids<Item>(_ sections: [SearchSection<Item>]) -> [String] {
        sections.map(\.id)
    }

    // MARK: - Which chips exist

    func testNonEmptyDropsGroupsWithNoResultsAndKeepsTheGivenOrder() {
        let sections = SearchSections.nonEmpty([
            group("tracks", ["one", "two"]),
            group("artists", []),
            group("albums", ["three"]),
            group("playlists", []),
            group("radios", ["four"]),
        ])

        XCTAssertEqual(ids(sections), ["tracks", "albums", "radios"])
    }

    func testNonEmptyIsEmptyWhenNothingMatched() {
        let sections = SearchSections.nonEmpty([
            group("tracks", [String]()),
            group("artists", [String]()),
        ])

        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - What a chip shows

    func testNoSelectionShowsEveryGroup() {
        let sections = [group("tracks", ["one"]), group("albums", ["two"])]

        XCTAssertEqual(ids(SearchSections.visible(sections, selection: nil)), ["tracks", "albums"])
    }

    func testASelectionShowsThatGroupAloneWithItsItemsIntact() {
        let sections = [
            group("tracks", ["one", "two"]),
            group("albums", ["three"]),
            group("radios", ["four"]),
        ]

        let visible = SearchSections.visible(sections, selection: "albums")

        XCTAssertEqual(ids(visible), ["albums"])
        XCTAssertEqual(visible.first?.items, ["three"])
    }

    /// The case that would otherwise leave the screen blank with a chip lit: the user picks
    /// Albums, searches for something else, and the new results have no albums in them.
    func testASelectionThatNamesNoGroupFallsBackToEveryGroup() {
        let sections = [group("tracks", ["one"]), group("artists", ["two"])]

        XCTAssertEqual(
            ids(SearchSections.visible(sections, selection: "albums")),
            ["tracks", "artists"]
        )
    }

    func testSelectingTheFirstOrLastGroupIsNotSpecial() {
        let sections = [group("tracks", ["one"]), group("albums", ["two"]), group("radios", ["three"])]

        XCTAssertEqual(ids(SearchSections.visible(sections, selection: "tracks")), ["tracks"])
        XCTAssertEqual(ids(SearchSections.visible(sections, selection: "radios")), ["radios"])
    }
}
