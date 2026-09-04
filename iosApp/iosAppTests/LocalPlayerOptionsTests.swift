import XCTest

/// Pins how `LocalPlayerOptions` labels the codec and buffer-size rows of the Local Player
/// section. The rule worth guarding is that every value Kotlin can hand over gets a
/// non-empty row: a known codec maps to its catalog key, an unknown one falls through to
/// its raw name instead of vanishing from the picker.
final class LocalPlayerOptionsTests: XCTestCase {

    func testEveryKnownCodecHasACatalogKey() {
        XCTAssertEqual(LocalPlayerOptions.codecLabelKey(for: "OPUS"), "codec_opus")
        XCTAssertEqual(LocalPlayerOptions.codecLabelKey(for: "FLAC"), "codec_flac")
        XCTAssertEqual(LocalPlayerOptions.codecLabelKey(for: "PCM"), "codec_pcm")
    }

    func testCodecLookupIgnoresCase() {
        // Kotlin sends the enum's name in upper case; a stored value from an older build might not be.
        XCTAssertEqual(LocalPlayerOptions.codecLabelKey(for: "opus"), "codec_opus")
    }

    func testAnUnknownCodecHasNoKeySoTheRawNameIsShown() {
        XCTAssertNil(LocalPlayerOptions.codecLabelKey(for: "AAC"))
        XCTAssertNil(LocalPlayerOptions.codecLabelKey(for: ""))
    }

    func testAStoredValueOffTheListStillGetsARow() {
        XCTAssertEqual(LocalPlayerOptions.codecRows(["OPUS", "FLAC"], current: "PCM"), ["OPUS", "FLAC", "PCM"])
        XCTAssertEqual(LocalPlayerOptions.codecRows(["OPUS", "FLAC"], current: "FLAC"), ["OPUS", "FLAC"])
        // An empty name is "nothing stored", not a codec; it must not become a blank row.
        XCTAssertEqual(LocalPlayerOptions.codecRows(["OPUS"], current: ""), ["OPUS"])

        XCTAssertEqual(LocalPlayerOptions.bufferSizeRows([5, 10, 15], current: 12), [5, 10, 12, 15])
        XCTAssertEqual(LocalPlayerOptions.bufferSizeRows([5, 10, 15], current: 10), [5, 10, 15])
    }

    func testBufferSizeLabelsCarryTheUnit() {
        let en = Locale(identifier: "en_US")

        XCTAssertEqual(LocalPlayerOptions.bufferSizeLabel(mb: 5, locale: en), "5 MB")
        XCTAssertEqual(LocalPlayerOptions.bufferSizeLabel(mb: 50, locale: en), "50 MB")
    }

    func testBufferSizeLabelsUseLocaleDigits() {
        // Arabic locales format digits differently; the label must follow the locale, not ASCII.
        let ar = Locale(identifier: "ar_EG")

        XCTAssertNotEqual(LocalPlayerOptions.bufferSizeLabel(mb: 15, locale: ar), "15 MB")
        XCTAssertTrue(LocalPlayerOptions.bufferSizeLabel(mb: 15, locale: ar).hasSuffix(" MB"))
    }
}
