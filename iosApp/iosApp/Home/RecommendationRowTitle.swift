import Foundation

/// Translates the titles of Music Assistant's built-in recommendation rows.
///
/// The server sends curated rows with both an English `name` and a stable `translation_key`, and
/// leaves the translating to whoever is displaying them — which is why the web frontend is
/// consistently in one language and this app was not. Servers newer than 2.9.11 resolve it
/// themselves for a connection that declares a locale, but that is unreleased and asking costs
/// an error in the log every launch (see the note in `iOSApp.init`), so the client does it.
///
/// **Deliberately only the library's own rows.** Providers define their own keys —
/// `recommendations.global_top_artists` from lastfm, and so on for every provider installed — so
/// that half of the key space grows without this app knowing, and any table here would drift
/// silently behind it. The nine below are fixed, defined by the server itself, and cover the rows
/// every install has. Everything else keeps the server's English name, which is a plain untranslated
/// string rather than a wrong or missing one.
enum RecommendationRowTitle {

    /// Server key → key in `Localizable.xcstrings`.
    ///
    /// An allowlist rather than a derived prefix on purpose: `String(localized:)` returns the key
    /// itself when it is missing, so deriving would put `recommendation_whatever` on screen the
    /// first time a server sent a key we had no string for. Falling back to the server's English
    /// name is always better than that. `RecommendationRowTitleTests` checks every entry here
    /// against the catalogue so the table cannot claim a string that does not exist.
    static let catalogueKeys: [String: String] = [
        "favorite_playlists": "recommendation_favorite_playlists",
        "favorite_radio_stations": "recommendation_favorite_radio_stations",
        "in_progress_items": "recommendation_in_progress_items",
        "random_albums": "recommendation_random_albums",
        "random_artists": "recommendation_random_artists",
        "recent_favorite_tracks": "recommendation_recent_favorite_tracks",
        "recently_added_albums": "recommendation_recently_added_albums",
        "recently_added_tracks": "recommendation_recently_added_tracks",
        "recently_played": "recommendation_recently_played",
    ]

    /// - Parameters:
    ///   - translationKey: the server's key, or nil on a row that has none (a provider folder, or
    ///     a server that already localized `name` for us).
    ///   - serverName: the row's `name` as it arrived. Used verbatim whenever the key is unknown.
    static func localized(translationKey: String?, serverName: String) -> String {
        guard let translationKey,
              let catalogueKey = catalogueKeys[translationKey]
        else { return serverName }
        return String(localized: String.LocalizationValue(catalogueKey))
    }
}
