import XCTest

/// Pins how `PlaybackSpeedOptions` turns the queue's current speed into menu rows and labels.
/// The one rule worth guarding is the splice: a speed the presets don't cover must still get
/// a checked row, or the submenu opens with nothing selected.
final class PlaybackSpeedOptionsTests: XCTestCase {

    func testAPresetSpeedLeavesTheListUntouched() {
        XCTAssertEqual(PlaybackSpeedOptions.rows(current: 1.5), PlaybackSpeedOptions.presets)
    }

    func testAnOffGridSpeedIsSplicedInWhereItSorts() {
        let rows = PlaybackSpeedOptions.rows(current: 1.1)

        XCTAssertEqual(rows, [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
    }

    func testFloatNoiseSnapsOntoItsPreset() {
        // The server stores plain floats; a value that is 1.25 for every practical purpose
        // must not become a second, unselectable row next to the real one.
        XCTAssertEqual(PlaybackSpeedOptions.rows(current: 1.2500000001), PlaybackSpeedOptions.presets)
        XCTAssertEqual(PlaybackSpeedOptions.normalized(0.999999), 1.0)
    }

    func testLabelsDropTrailingZeros() {
        let en = Locale(identifier: "en_US")

        XCTAssertEqual(PlaybackSpeedOptions.label(for: 1.0, locale: en), "1×")
        XCTAssertEqual(PlaybackSpeedOptions.label(for: 1.25, locale: en), "1.25×")
        XCTAssertEqual(PlaybackSpeedOptions.label(for: 0.5, locale: en), "0.5×")
    }

    func testLabelsUseTheLocaleDecimalSeparator() {
        XCTAssertEqual(PlaybackSpeedOptions.label(for: 1.25, locale: Locale(identifier: "de_DE")), "1,25×")
    }
}
