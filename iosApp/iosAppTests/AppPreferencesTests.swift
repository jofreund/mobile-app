import XCTest

/// The settings moved from Kotlin's `SettingsRepository` to `AppPreferences` must read back
/// exactly what Kotlin wrote — these are the encodings from that class, verbatim, including
/// kotlinx.serialization's pretty-printed JSON — and write what they themselves can read.
@MainActor
final class AppPreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "AppPreferencesTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Reading what Kotlin stored

    func testReadsKotlinThemeNames() {
        defaults.set("FollowSystem", forKey: "theme")
        XCTAssertEqual(AppPreferences(defaults: defaults).theme, .followSystem)
        defaults.set("Dark", forKey: "theme")
        XCTAssertEqual(AppPreferences(defaults: defaults).theme, .dark)
    }

    func testReadsKotlinLiveActivityVisibilityNames() {
        defaults.set("WHILE_PLAYING", forKey: "live_activity_visibility")
        XCTAssertEqual(AppPreferences(defaults: defaults).liveActivityVisibility, .whilePlaying)
    }

    func testReadsKotlinPrettyPrintedHomeRows() {
        defaults.set(
            """
            [
                {
                    "id": "recently_played",
                    "enabled": true
                },
                {
                    "id": "discover",
                    "enabled": false
                }
            ]
            """,
            forKey: "home_rows_config"
        )
        XCTAssertEqual(
            AppPreferences(defaults: defaults).homeRows,
            [HomeRowPref(id: "recently_played", enabled: true), HomeRowPref(id: "discover", enabled: false)]
        )
    }

    func testReadsKotlinLibraryCategoryPairs() {
        defaults.set("ALBUMS:1,ARTISTS:0,TRACKS:1", forKey: "library_tabs_config")
        XCTAssertEqual(
            AppPreferences(defaults: defaults).libraryCategories,
            [
                LibraryCategoryPref(name: "ALBUMS", enabled: true),
                LibraryCategoryPref(name: "ARTISTS", enabled: false),
                LibraryCategoryPref(name: "TRACKS", enabled: true),
            ]
        )
    }

    func testReadsKotlinViewModePerMediaType() {
        defaults.set("LIST", forKey: "view_mode_ALBUM")
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.viewMode(forMediaType: "ALBUM"), .list)
        XCTAssertEqual(prefs.viewMode(forMediaType: "ARTIST"), .grid, "Absent means grid")
    }

    // MARK: - Defaults

    func testDefaultsWhenNothingIsStored() {
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.theme, .followSystem)
        XCTAssertEqual(prefs.liveActivityVisibility, .always)
        XCTAssertEqual(prefs.homeRows, [])
        XCTAssertEqual(prefs.libraryCategories, [])
    }

    func testGarbageFallsBackToDefaults() {
        defaults.set("Sepia", forKey: "theme")
        defaults.set("not json", forKey: "home_rows_config")
        defaults.set("ALBUMS", forKey: "library_tabs_config")
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.theme, .followSystem)
        XCTAssertEqual(prefs.homeRows, [])
        XCTAssertEqual(prefs.libraryCategories, [])
    }

    // MARK: - Round trips

    func testWritesSurviveAReload() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.theme = .light
        prefs.liveActivityVisibility = .whilePlaying
        prefs.homeRows = [HomeRowPref(id: "a", enabled: false), HomeRowPref(id: "b", enabled: true)]
        prefs.libraryCategories = [LibraryCategoryPref(name: "PLAYLISTS", enabled: false)]
        prefs.setViewMode(.list, forMediaType: "TRACK")

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.theme, .light)
        XCTAssertEqual(reloaded.liveActivityVisibility, .whilePlaying)
        XCTAssertEqual(reloaded.homeRows, prefs.homeRows)
        XCTAssertEqual(reloaded.libraryCategories, prefs.libraryCategories)
        XCTAssertEqual(reloaded.viewMode(forMediaType: "TRACK"), .list)
    }

    func testStoredEncodingsStayKotlinShaped() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.theme = .dark
        prefs.libraryCategories = [
            LibraryCategoryPref(name: "ALBUMS", enabled: true),
            LibraryCategoryPref(name: "ARTISTS", enabled: false),
        ]
        prefs.setViewMode(.grid, forMediaType: "ALBUM")
        XCTAssertEqual(defaults.string(forKey: "theme"), "Dark")
        XCTAssertEqual(defaults.string(forKey: "library_tabs_config"), "ALBUMS:1,ARTISTS:0")
        XCTAssertEqual(defaults.string(forKey: "view_mode_ALBUM"), "GRID")
    }

    // MARK: - Observation

    func testLiveActivityObserverFiresOnEveryLaterChange() async {
        let prefs = AppPreferences(defaults: defaults)
        var seen: [LiveActivityVisibility] = []
        prefs.observeLiveActivityVisibility { seen.append($0) }

        prefs.liveActivityVisibility = .whilePlaying
        await Task.yield()
        await Task.yield()
        prefs.liveActivityVisibility = .always
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(seen, [.whilePlaying, .always])
    }

    // MARK: - Kids mode

    func testKidsModeDefaultsOffWithNoPlayerAndTheDefaultTypes() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.kidsModeEnabled)
        XCTAssertNil(preferences.kidsModePlayerId)
        XCTAssertEqual(preferences.kidsModeMediaTypes, KidsMediaType.defaultSelection)
    }

    func testKidsModeSettingsRoundTrip() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.kidsModeEnabled = true
        preferences.kidsModePlayerId = "media_player.kids_room"
        preferences.kidsModeMediaTypes = [.album, .radio]

        let reread = AppPreferences(defaults: defaults)
        XCTAssertTrue(reread.kidsModeEnabled)
        XCTAssertEqual(reread.kidsModePlayerId, "media_player.kids_room")
        XCTAssertEqual(reread.kidsModeMediaTypes, [.album, .radio])
        XCTAssertEqual(defaults.string(forKey: "kids_mode_media_types"), "album,radio")
    }

    func testClearingTheKidsPlayerRemovesTheKey() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.kidsModePlayerId = "p1"
        preferences.kidsModePlayerId = nil
        XCTAssertNil(defaults.string(forKey: "kids_mode_player_id"))
        XCTAssertNil(AppPreferences(defaults: defaults).kidsModePlayerId)
    }

    func testAMeaninglessStoredTypeListFallsBackToTheDefault() {
        defaults.set("artist", forKey: "kids_mode_media_types")
        XCTAssertEqual(AppPreferences(defaults: defaults).kidsModeMediaTypes, KidsMediaType.defaultSelection)
    }
}
