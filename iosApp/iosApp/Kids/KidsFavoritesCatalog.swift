import Foundation

/// The media types the kids carousel can be fed from — the ones a tap plays as a whole. Artists
/// and genres are not here on purpose: in the rest of the app they open a page, and kids mode
/// has no pages.
///
/// Pure Swift, like `AppPreferences`: the test target compiles this file directly and links
/// nothing from `MusicAssistantKit`. `serverValue` is what `MediaType.fromServer` accepts, the
/// same contract `LibraryLinkCategory` uses for deep links.
enum KidsMediaType: String, CaseIterable, Identifiable {
    case album, playlist, audiobook, track, podcast, radio

    var id: String { rawValue }
    var serverValue: String { rawValue }

    /// Albums, playlists and audiobooks: what a child's favorites are most likely to be, and
    /// the three that play as one unit without surprises. Tracks, podcasts and radio are a
    /// toggle away in Settings.
    static let defaultSelection: [KidsMediaType] = [.album, .playlist, .audiobook]

    /// The Library tab's own plural labels, so the Settings toggles read the same as the
    /// categories they mirror.
    var localizationKey: String {
        switch self {
        case .album: "media_type_albums"
        case .playlist: "media_type_playlists"
        case .audiobook: "media_type_audiobooks"
        case .track: "media_type_tracks"
        case .podcast: "media_type_podcasts"
        case .radio: "media_type_radio"
        }
    }

    /// Comma-separated raw values — the shape `AppPreferences.libraryCategories` stores.
    static func encode(_ types: [KidsMediaType]) -> String {
        types.map(\.rawValue).joined(separator: ",")
    }

    /// Nil for an absent key (first run) and for a stored value naming no known type, so the
    /// caller falls back to `defaultSelection`. Unknown names inside an otherwise valid list are
    /// dropped. Order is kept: it is the carousel's section order.
    static func decode(_ raw: String?) -> [KidsMediaType]? {
        guard let raw, !raw.isEmpty else { return nil }
        let types = raw.split(separator: ",").compactMap { KidsMediaType(rawValue: String($0)) }
        return types.isEmpty ? nil : types
    }

    /// `types` with `type` switched on or off, normalised to declaration order, and never
    /// emptied: the last enabled type stays, the way the Library tab keeps its last category.
    static func toggling(_ type: KidsMediaType, on: Bool, in types: [KidsMediaType]) -> [KidsMediaType] {
        if on {
            return allCases.filter { $0 == type || types.contains($0) }
        }
        let remaining = types.filter { $0 != type }
        return remaining.isEmpty ? types : remaining
    }
}

/// How the kids view turns one fetch per media type into the carousel's list, and how it tells
/// "nothing is a favorite" apart from "the server could not be reached".
enum KidsFavoritesCatalog {

    enum LoadOutcome<Item: Equatable>: Equatable {
        /// A fetch timed out, or every fetch came back empty while the connection was not ready
        /// for commands — the nil-vs-empty rule in `architecture.md`. The caller keeps what is on
        /// screen and retries when the connection arrives.
        case failed
        case loaded([Item])
    }

    /// One entry per enabled type, in the order they were fetched; `nil` is a timeout.
    static func outcome<Item: Equatable>(
        sections: [[Item]?],
        isReady: Bool,
        id: (Item) -> String
    ) -> LoadOutcome<Item> {
        var loaded: [[Item]] = []
        for section in sections {
            guard let section else { return .failed }
            loaded.append(section)
        }
        if loaded.allSatisfy(\.isEmpty) && !isReady { return .failed }
        return .loaded(merge(loaded, id: id))
    }

    /// Sections in the caller's order, each in the order the server returned it, first
    /// occurrence of an id wins. Ids are `provider:itemId`, so a clash is unlikely, but a
    /// duplicate inside a `ForEach` is a layout the user sees, and this is cheap.
    static func merge<Item>(_ sections: [[Item]], id: (Item) -> String) -> [Item] {
        var seen: Set<String> = []
        var merged: [Item] = []
        for item in sections.joined() where seen.insert(id(item)).inserted {
            merged.append(item)
        }
        return merged
    }
}

/// The question behind the lock: an addition a child below school age will not get past and a
/// parent solves without thinking. Not security — Guided Access is the lock-down; this only
/// keeps a stray tap from landing in Settings.
struct ParentGateChallenge: Equatable {
    let left: Int
    let right: Int

    var answer: Int { left + right }

    /// Two two-digit operands, so the sum needs a carry more often than not.
    static func random(using generator: inout some RandomNumberGenerator) -> ParentGateChallenge {
        ParentGateChallenge(
            left: Int.random(in: 12...39, using: &generator),
            right: Int.random(in: 13...48, using: &generator)
        )
    }

    static func random() -> ParentGateChallenge {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// Whitespace around the number is forgiven; anything else is a wrong answer.
    func accepts(_ input: String) -> Bool {
        Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) == answer
    }
}
