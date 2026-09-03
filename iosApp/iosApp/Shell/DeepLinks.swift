import Foundation
import Observation

/// A page reachable via a `musicassistant://app/<page>` deep link or its Universal Link twin,
/// `https://<domain>/app/<page>`.
enum DeepLink: Equatable {
    case home
    /// Library tab. `category` nil = tab root; set = that category's list (`/library/<category>`).
    case library(category: LibraryLinkCategory?)
    case search
    /// Expand the player over the current tab. `playerId` nil = whichever player is selected;
    /// set (`/players/<playerId>`) = select that player first — the Live Activity links here
    /// with the id of the player it was showing.
    case players(playerId: String?)
}

/// The `/library/<category>` contract. An explicit table so the public URL names stay stable
/// and this file needs no Kotlin type; `serverValue` is what `MediaType.fromServer` accepts.
enum LibraryLinkCategory: String, CaseIterable {
    case artists, albums, tracks, playlists, audiobooks, podcasts, radios, genres

    var serverValue: String {
        switch self {
        case .artists: "artist"
        case .albums: "album"
        case .tracks: "track"
        case .playlists: "playlist"
        case .audiobooks: "audiobook"
        case .podcasts: "podcast"
        case .radios: "radio"
        case .genres: "genre"
        }
    }
}

enum DeepLinkParser {

    /// Reads a page deep link. Accepts both forms:
    ///  - custom scheme:  `musicassistant://app/<page>`   (host == "app")
    ///  - Universal Link: `https://<domain>/app/<page>`  (first path segment == "app")
    ///
    /// The owning domain is enforced by the OS (associated domains), so this keys only on the
    /// `app` marker and the page segment. Returns nil for anything else — an OAuth callback, an
    /// unknown page, a present-but-unknown library category (the whole link is rejected rather
    /// than silently landing on the tab root), or an unrelated URL.
    static func parse(_ url: URL) -> DeepLink? {
        // `pathComponents` is percent-decoded and drops empty segments; the leading "/" is
        // the only entry to skip.
        let segments = url.pathComponents.filter { $0 != "/" }
        let route: [String]
        if url.host == "app" {
            route = segments
        } else if segments.first == "app" {
            route = Array(segments.dropFirst())
        } else {
            return nil
        }
        switch route.first ?? "home" { // bare ".../app" → home
        case "home":
            return .home
        case "library":
            guard let sub = route.dropFirst().first else { return .library(category: nil) }
            guard let category = LibraryLinkCategory(rawValue: sub) else { return nil }
            return .library(category: category)
        case "search":
            return .search
        case "players":
            // The id is taken verbatim (already percent-decoded) — player ids are server-issued
            // opaque strings, so there is no closed set to validate against; the consumer
            // treats an unknown id as absent.
            return .players(playerId: route.dropFirst().first)
        default:
            return nil
        }
    }
}

/// App-wide carrier for the latest pending deep link.
///
/// Holds the *latest pending* destination as retained state rather than a one-shot event, on
/// purpose: the consumer (`AppTabView`) can be built, torn down and rebuilt during the
/// cold-launch auth churn, and a one-shot event would be drained by the first, doomed
/// instance. A retained value survives that; the consumer applies it once it is on screen and
/// then calls `consume`, so it is honoured exactly once.
@Observable
@MainActor
final class DeepLinkQueue {

    static let shared = DeepLinkQueue()

    private(set) var pending: DeepLink?

    /// Parses `url` and stores the result as the pending destination; ignores anything that is
    /// not a page deep link.
    func handle(_ url: URL) {
        guard let link = DeepLinkParser.parse(url) else { return }
        pending = link
    }

    /// Clears `link` once applied. No-op if a newer link superseded it meanwhile.
    func consume(_ link: DeepLink) {
        if pending == link { pending = nil }
    }
}

// MARK: - OAuth callback

/// The one place that knows what an OAuth callback URL looks like. Two callers share it: the
/// in-app auth session (`OAuthWebSession`) and the deep-link dispatcher in `iOSApp.swift`.
/// Separate copies of the scheme used to drift apart silently — a callback scheme that does
/// not match the one the session waits for produces a sheet that hangs until the user gives
/// up. The server is told `returnURL` when the flow starts, so Swift owns the whole contract.
enum OAuthCallbackParser {

    /// Outcome of reading an incoming URL as an OAuth callback.
    enum Result: Equatable {
        /// The provider returned an authorization code.
        case code(String)
        /// The callback shape matched but carried a failure, or no code at all.
        case failed(reason: String)
        /// Not an OAuth callback — some other deep link, or not a URL at all.
        case notOAuth
    }

    /// Bare scheme, for `ASWebAuthenticationSession.Callback.customScheme`. The session
    /// matches on the scheme alone and silently never fires if given a full URL. Must stay in
    /// step with `CFBundleURLSchemes` in `Info.plist`, which is what makes iOS deliver the
    /// callback to this app at all.
    static let scheme = "musicassistant"

    private static let host = "auth"
    private static let path = "/callback"

    /// Full redirect URL, handed to the server's `auth/authorization_url` call.
    static let returnURL = "\(scheme)://\(host)\(path)"

    /// Reads `url` as an OAuth callback. A URL that matches the shape but carries `?error=`
    /// is reported as `failed` rather than dropped — the user is sitting in front of a spinner
    /// that only an outcome can clear.
    static func parse(_ url: URL) -> Result {
        guard url.scheme == scheme, url.host == host,
              trimmingTrailingSlash(url.path) == path
        else { return .notOAuth }

        let query = queryItems(of: url)
        if let code = query["code"], !code.isEmpty { return .code(code) }

        let error = [query["error_description"], query["error"]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        return .failed(reason: error ?? "No token in OAuth callback")
    }

    /// Convenience over `parse` for callers that only have a string.
    static func parse(_ string: String) -> Result {
        guard let url = URL(string: string) else { return .notOAuth }
        return parse(url)
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// Form-decoded query: `+` is a space, as Ktor's parser (and every OAuth provider) treats
    /// it — `URLComponents` would leave it literal.
    private static func queryItems(of url: URL) -> [String: String] {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(parts[0])
            let value = parts.count > 1 ? decode(parts[1]) : ""
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    private static func decode(_ component: Substring) -> String {
        component.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(component)
    }
}
