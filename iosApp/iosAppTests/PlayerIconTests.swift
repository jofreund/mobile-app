import XCTest

// `PlayerIcon.swift` and `PlayerIconCatalog.swift` are compiled into this target directly —
// `iosAppTests` has no host application, so there is no `iosApp` module to import.
// See DEV-ENVIRONMENT.md.

final class PlayerIconTests: XCTestCase {

    /// The current server sends canonical ids, and they must survive untouched — an id is the
    /// name of an imageset, so anything else here draws the wrong artwork or none.
    func testCanonicalIdsPassThrough() {
        XCTAssertEqual(PlayerIcon.resolve("sonos", isGroup: false), "sonos")
        XCTAssertEqual(PlayerIcon.resolve("homepod-mini", isGroup: false), "homepod-mini")
        XCTAssertEqual(PlayerIcon.resolve("speakers", isGroup: true), "speakers")
    }

    /// Servers that have not run the icon migration still send Material names. This is the case
    /// the old SF Symbol table existed for, and the whole reason the legacy map is vendored.
    func testLegacyMaterialNamesAreMigrated() {
        XCTAssertEqual(PlayerIcon.resolve("mdi-speaker", isGroup: false), "speaker")
        XCTAssertEqual(PlayerIcon.resolve("mdi-cellphone", isGroup: false), "smartphone")
        XCTAssertEqual(PlayerIcon.resolve("mdi-television", isGroup: false), "tv")
    }

    /// Substring matching is what the SF Symbol table had to do, and `mdi-speaker-multiple`
    /// landing on `speaker` was the failure it kept having to be ordered around. The map is
    /// exact, so the qualifier is read rather than swallowed.
    func testQualifiedNamesAreNotSwallowedByTheirBase() {
        XCTAssertEqual(PlayerIcon.resolve("mdi-speaker-multiple", isGroup: false), "speakers")
        XCTAssertEqual(PlayerIcon.resolve("mdi-speaker", isGroup: false), "speaker")
    }

    func testCaseAndWhitespaceAreIgnored() {
        XCTAssertEqual(PlayerIcon.resolve("  MDI-Speaker ", isGroup: false), "speaker")
    }

    /// An id from a newer icon set than the one vendored here, or a name no map covers. There is
    /// no artwork to draw, so it falls back by kind rather than to a bare `speaker` — a group
    /// still has to read as a group.
    func testUnknownValuesFallBackByKind() {
        XCTAssertEqual(PlayerIcon.resolve("turntable-9000", isGroup: false), "speaker")
        XCTAssertEqual(PlayerIcon.resolve("turntable-9000", isGroup: true), "speakers")
        XCTAssertEqual(PlayerIcon.resolve(nil, isGroup: false), "speaker")
        XCTAssertEqual(PlayerIcon.resolve(nil, isGroup: true), "speakers")
        XCTAssertEqual(PlayerIcon.resolve("", isGroup: true), "speakers")
    }

    /// Every value the legacy map can produce, and both defaults, have to be ids the set
    /// actually contains — otherwise a migrated server would resolve to a missing imageset.
    func testEveryResolvableValueIsADrawableId() {
        for (legacy, id) in PlayerIconCatalog.legacyIds {
            XCTAssertTrue(PlayerIconCatalog.ids.contains(id), "\(legacy) maps to unknown id \(id)")
        }
        XCTAssertTrue(PlayerIconCatalog.ids.contains(PlayerIconCatalog.playerDefault))
        XCTAssertTrue(PlayerIconCatalog.ids.contains(PlayerIconCatalog.groupDefault))
        XCTAssertTrue(PlayerIconCatalog.ids.contains(PlayerIconCatalog.fallback))
    }
}
