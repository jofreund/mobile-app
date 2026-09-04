import XCTest

/// Pins how `LocalPlayerOptions` labels the codec and buffer-size rows of the Local Player
/// section. The rule worth guarding is that every value Kotlin can hand over gets a
/// non-empty row: a known codec maps to its catalog key, an unknown one falls through to
/// its raw name, and a buffer size that matches no tier still appears as its own row.
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

    func testAStoredCodecOffTheListStillGetsARow() {
        XCTAssertEqual(LocalPlayerOptions.codecRows(["OPUS", "FLAC"], current: "PCM"), ["OPUS", "FLAC", "PCM"])
        XCTAssertEqual(LocalPlayerOptions.codecRows(["OPUS", "FLAC"], current: "FLAC"), ["OPUS", "FLAC"])
        // An empty name is "nothing stored", not a codec; it must not become a blank row.
        XCTAssertEqual(LocalPlayerOptions.codecRows(["OPUS"], current: ""), ["OPUS"])
    }

    private let kernelGrid = Array(stride(from: 5, through: 50, by: 5))

    func testEveryTierIsOnTheKernelGrid() {
        // The tiers are Swift constants; the kernel's grid is what the server may be told.
        for tier in LocalPlayerOptions.tiers {
            XCTAssertTrue(kernelGrid.contains(tier.mb), "\(tier.mb) MB is not a size the kernel accepts")
        }
    }

    func testTheDefaultSizeIsATier() {
        // `SendspinConfig.BUFFER_MB_DEFAULT` is 15; the "(default)" marker must land on a named row.
        XCTAssertTrue(LocalPlayerOptions.tiers.contains { $0.mb == 15 && $0.tierKey != nil })
    }

    func testACurrentValueOnATierAddsNoRow() {
        let rows = LocalPlayerOptions.bufferSizeRows(kernelOptions: kernelGrid, current: 30)

        XCTAssertEqual(rows, LocalPlayerOptions.tiers)
    }

    func testACurrentValueOffTheTiersGetsAnUntitledRowInOrder() {
        let rows = LocalPlayerOptions.bufferSizeRows(kernelOptions: kernelGrid, current: 20)

        XCTAssertEqual(rows.map(\.mb), [5, 15, 20, 30, 50])
        let custom = rows.first { $0.mb == 20 }
        XCTAssertNil(custom?.tierKey)
        XCTAssertEqual(custom?.descriptionKey, "settings_buffer_tier_custom_hint")
    }

    func testATierOutsideTheKernelGridIsDropped() {
        // If the kernel ever lowers its maximum, the picker must not offer a size it would reject.
        let rows = LocalPlayerOptions.bufferSizeRows(kernelOptions: [5, 10, 15, 20, 25, 30], current: 15)

        XCTAssertEqual(rows.map(\.mb), [5, 15, 30])
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
