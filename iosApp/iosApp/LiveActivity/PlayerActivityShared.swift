import ActivityKit
import AppIntents
import Foundation

/// Everything the app target and the TaktgeberWidgets extension must agree on, in one file that
/// compiles into both. The extension deliberately does NOT link MusicAssistantKit (a widget
/// process has a ~30 MB memory ceiling and no use for the KMP graph), so anything Kotlin-touching
/// here is fenced with `canImport` — in the extension those branches compile to nothing, which is
/// fine: a `LiveActivityIntent` is always executed in the *app's* process, the extension's copy
/// exists only so `Button(intent:)` can name the type.

// MARK: - Activity contract

/// One activity follows the *selected* player, so everything — including which player the button
/// controls — lives in the dynamic `ContentState` rather than in the (immutable) attributes.
/// ActivityKit caps the encoded content state at 4 KB; artwork therefore travels as a file name
/// in the shared app-group container, never as bytes.
struct PlayerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var playerId: String
        var playerName: String
        var title: String
        var subtitle: String?
        var isPlaying: Bool
        /// File name inside `PlayerActivityArtworkStore`'s container, or nil for no artwork.
        var artworkFileName: String?
    }
}

// MARK: - Shared artwork location

/// Resolves artwork files the app writes for the widget process to read. Fails soft: a nil
/// container (entitlement missing or not yet provisioned) just means artwork-less presentation.
enum PlayerActivityArtworkStore {
    static let appGroupId = "group.com.jofreund.taktgeber"

    static var containerUrl: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func url(for fileName: String) -> URL? {
        containerUrl?.appendingPathComponent(fileName, isDirectory: false)
    }
}

// MARK: - Play/pause intent

/// The Live Activity button's action. `LiveActivityIntent` conformance is what routes execution
/// into the app process (background-launching it if needed) instead of the widget extension —
/// the whole feature hangs on that, so don't "simplify" it to a plain `AppIntent`.
struct PlayerPlayPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    /// Not offered in Shortcuts/Spotlight — this exists solely as the activity button's action.
    static let isDiscoverable = false

    @Parameter(title: "Player")
    var playerId: String

    init() {}

    init(playerId: String) {
        self.playerId = playerId
    }

    func perform() async throws -> some IntentResult {
        #if canImport(MusicAssistantKit)
        await PlayerActivityCommand.togglePlayPause(playerId: playerId)
        #endif
        return .result()
    }
}
