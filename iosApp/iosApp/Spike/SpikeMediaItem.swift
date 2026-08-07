import SwiftUI
import ComposeApp

/// SwiftUI-shaped projection of the Kotlin `AppMediaItem` sealed hierarchy.
///
/// `AppMediaItem` reaches Swift as an Obj-C class tree, which SwiftUI cannot use
/// directly: it is not `Identifiable`, not `Hashable` in a way `NavigationPath`
/// accepts, and branching on it means a chain of `is` casts at every call site.
/// This struct does that work once, at the bridge boundary, and keeps a reference
/// to `kotlin` so actions can be dispatched back through `KmpHelper`.
///
/// Note what this deliberately does *not* do: it does not re-derive `displayName`
/// or `subtitle`. Those are Kotlin-side presentation policy (album version suffixes,
/// artist joining) that Android and the server already agree on.
struct SpikeMediaItem: Identifiable, Hashable {

    /// What the item is, for icon and drilldown purposes.
    ///
    /// A flat enum rather than a mirror of the sealed hierarchy: the spike only
    /// branches on "which SF Symbol" and "what can I drill into," and 11 cases
    /// of which 4 are reachable would be noise. Phase C replaces the `is` chain
    /// below with the compiler-checked `AppMediaItemVisitor`.
    enum Kind {
        case album, artist, track, playlist, podcast, podcastEpisode
        case audiobook, radioStation, genre, folder, other

        var symbol: String {
            switch self {
            case .album: "square.stack"
            case .artist: "music.microphone"
            case .track: "music.note"
            case .playlist: "music.note.list"
            case .podcast: "antenna.radiowaves.left.and.right"
            case .podcastEpisode: "waveform"
            case .audiobook: "book.fill"
            case .radioStation: "dot.radiowaves.left.and.right"
            case .genre: "guitars"
            case .folder: "folder"
            case .other: "music.note"
            }
        }

        /// Whether tapping should push a child list rather than play.
        var isBrowsable: Bool {
            switch self {
            case .album, .artist, .playlist, .podcast: true
            default: false
            }
        }

        /// Artists read better as circles, everything else as rounded squares —
        /// the same convention Music and most players use.
        var prefersCircularArtwork: Bool { self == .artist }
    }

    let id: String
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let kind: Kind
    let isFavorite: Bool
    let kotlin: AppMediaItem

    init(_ item: AppMediaItem) {
        // itemId is only unique within a provider; the library and a streaming
        // provider can both hold id "1234".
        self.id = "\(item.provider):\(item.itemId)"
        self.title = item.displayName
        self.subtitle = item.subtitle
        self.artworkURL = item.image(type: ImageType.thumb)?.url.flatMap(URL.init(string:))
        self.isFavorite = item.favorite?.boolValue ?? false
        self.kotlin = item

        self.kind = switch item {
        case is Album: .album
        case is Artist: .artist
        case is Track: .track
        case is Playlist: .playlist
        case is Podcast: .podcast
        case is PodcastEpisode: .podcastEpisode
        case is Audiobook: .audiobook
        case is RadioStation: .radioStation
        case is Genre: .genre
        case is RecommendationFolder: .folder
        default: .other
        }
    }

    static func == (lhs: SpikeMediaItem, rhs: SpikeMediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Array where Element == AppMediaItem {
    var asSpikeItems: [SpikeMediaItem] { map(SpikeMediaItem.init) }
}
