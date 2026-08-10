import XCTest

// `RecommendationRowTitle.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

final class RecommendationRowTitleTests: XCTestCase {

    /// The catalogue is read off disk rather than through `Bundle`: this target has no host app,
    /// so `String(localized:)` here resolves against the xctest bundle and would just hand back
    /// the key. Reading the source of truth is what makes the check meaningful.
    private func catalogue() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // iosAppTests
            .deletingLastPathComponent()  // iosApp
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appending(path: "iosApp/iosApp/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any])
    }

    /// The table names catalogue keys as strings, so nothing but a test stops it from pointing at
    /// one that does not exist — and the symptom would be `recommendation_recently_played` shown
    /// as a row heading, in the language the user was trying to get away from.
    func testEveryMappedKeyExistsInTheCatalogue() throws {
        let strings = try catalogue()

        for (serverKey, catalogueKey) in RecommendationRowTitle.catalogueKeys {
            let entry = strings[catalogueKey] as? [String: Any]
            XCTAssertNotNil(entry, "\(serverKey) maps to \(catalogueKey), which is not in the catalogue")

            let localizations = entry?["localizations"] as? [String: Any]
            for language in ["en", "de"] {
                let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                XCTAssertFalse(
                    (value ?? "").isEmpty,
                    "\(catalogueKey) has no \(language) translation"
                )
            }
        }
    }

    /// Pins the set to what the server actually sends, so a typo in a server key — which would
    /// fail open, silently leaving that row in English — shows up here instead.
    func testTableCoversExactlyTheServersLibraryRows() {
        XCTAssertEqual(
            Set(RecommendationRowTitle.catalogueKeys.keys),
            [
                "favorite_playlists",
                "favorite_radio_stations",
                "in_progress_items",
                "random_albums",
                "random_artists",
                "recent_favorite_tracks",
                "recently_added_albums",
                "recently_added_tracks",
                "recently_played",
            ]
        )
    }

    // MARK: - Fallback

    /// Provider rows carry keys this app has never heard of, by design. Their English name is the
    /// right answer — an untranslated string, rather than a wrong or missing one.
    func testUnknownKeyKeepsTheServerName() {
        XCTAssertEqual(
            RecommendationRowTitle.localized(
                translationKey: "recommendations.global_top_artists",
                serverName: "Global Top Artists"
            ),
            "Global Top Artists"
        )
    }

    /// A server that localizes for itself strips the key and sends a translated `name`; that name
    /// must survive untouched.
    func testMissingKeyKeepsTheServerName() {
        XCTAssertEqual(
            RecommendationRowTitle.localized(translationKey: nil, serverName: "Zuletzt gespielt"),
            "Zuletzt gespielt"
        )
    }

    func testEmptyKeyKeepsTheServerName() {
        XCTAssertEqual(
            RecommendationRowTitle.localized(translationKey: "", serverName: "Whatever"),
            "Whatever"
        )
    }
}
