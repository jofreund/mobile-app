import Foundation
import Observation

/// Dark / Light / Follow-System. Raw values are the names Kotlin's `ThemeSetting` enum stored,
/// so an existing choice survives the move.
enum ThemeSetting: String, CaseIterable {
    case dark = "Dark"
    case light = "Light"
    case followSystem = "FollowSystem"
}

/// When the lock screen / Dynamic Island Live Activity is shown. Raw values are Kotlin's
/// `LiveActivityVisibility` names.
enum LiveActivityVisibility: String, CaseIterable {
    /// Whenever the selected player has something loaded, playing or not. The historic behavior.
    case always = "ALWAYS"
    /// Only while at least one player is actually playing; the activity ends when they all stop.
    case whilePlaying = "WHILE_PLAYING"
}

/// Grid or list for a library category. Raw values are Kotlin's `ViewMode` names.
enum ViewMode: String {
    case grid = "GRID"
    case list = "LIST"

    var toggled: ViewMode { self == .grid ? .list : .grid }
}

/// One Home row: visible or hidden, in display order. JSON field names match what Kotlin wrote.
struct HomeRowPref: Codable, Equatable {
    var id: String
    var enabled: Bool
}

/// One Library category: visible or hidden, in display order.
struct LibraryCategoryPref: Equatable {
    var name: String
    var enabled: Bool
}

/// The UI-only settings, persisted in `UserDefaults` under the keys and encodings
/// `SettingsRepository` used while these lived in Kotlin. Nothing Kotlin-side reads any of
/// them, so they crossed the bridge for no reason: five `NativeStateFlow`s and their get/set
/// pairs became this one `@Observable` object that SwiftUI can bind to directly.
///
/// Pure Swift on purpose: the test target compiles this file directly and links nothing from
/// `MusicAssistantKit`. Media types are passed as their Kotlin `name` string for that reason.
///
/// `multiplatform-settings`' no-arg factory wrote to `UserDefaults.standard`, which is what
/// `shared` reads, so nothing migrates. The two legacy migrations Kotlin still carried
/// (`hidden_recommendation_folders`, `items_row_mode`) predate every build that has run on a
/// device this year and are not carried over.
@Observable
@MainActor
final class AppPreferences {

    static let shared = AppPreferences(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = ThemeSetting(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .followSystem
        liveActivityVisibility = LiveActivityVisibility(
            rawValue: defaults.string(forKey: Keys.liveActivityVisibility) ?? ""
        ) ?? .always
        homeRows = Self.decodeHomeRows(defaults.string(forKey: Keys.homeRows))
        libraryCategories = Self.decodeLibraryCategories(defaults.string(forKey: Keys.libraryCategories))
        kidsModeEnabled = defaults.bool(forKey: Keys.kidsModeEnabled)
        kidsModePlayerId = defaults.string(forKey: Keys.kidsModePlayerId)
        kidsModeMediaTypes = KidsMediaType.decode(defaults.string(forKey: Keys.kidsModeMediaTypes))
            ?? KidsMediaType.defaultSelection
    }

    // MARK: - Theme

    var theme: ThemeSetting {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    // MARK: - Live Activity

    var liveActivityVisibility: LiveActivityVisibility {
        didSet { defaults.set(liveActivityVisibility.rawValue, forKey: Keys.liveActivityVisibility) }
    }

    /// For observers that are not views. Fires on every later change (not immediately), on the
    /// main actor, for as long as `self` lives.
    func observeLiveActivityVisibility(_ onChange: @escaping @MainActor (LiveActivityVisibility) -> Void) {
        observe(\.liveActivityVisibility, onChange)
    }

    // MARK: - Home rows

    /// Visibility and user-defined order in one list. Order is display order; `enabled == false`
    /// is hidden. JSON, because folder ids are arbitrary server strings.
    var homeRows: [HomeRowPref] {
        didSet {
            if let data = try? JSONEncoder().encode(homeRows), let json = String(data: data, encoding: .utf8) {
                defaults.set(json, forKey: Keys.homeRows)
            }
        }
    }

    // MARK: - Library categories

    /// Visibility and order of the Library tab's categories; empty until first customized.
    /// Stored as comma-separated `NAME:1|0` pairs.
    var libraryCategories: [LibraryCategoryPref] {
        didSet {
            let encoded = libraryCategories.map { "\($0.name):\($0.enabled ? "1" : "0")" }.joined(separator: ",")
            defaults.set(encoded, forKey: Keys.libraryCategories)
        }
    }

    // MARK: - Kids mode

    /// Whether the shell shows `KidsFavoritesView` in place of the tab shell. Off by default;
    /// meant for a device signed in with a child's account (`.claude/kids-favorites-mode.md`).
    var kidsModeEnabled: Bool {
        didSet { defaults.set(kidsModeEnabled, forKey: Keys.kidsModeEnabled) }
    }

    /// The player kids mode drives, applied on top of the app's selection whenever it is in the
    /// list. Nil means "whichever is selected" — for an account the server restricts to one
    /// player, the only one there is.
    var kidsModePlayerId: String? {
        didSet {
            if let kidsModePlayerId {
                defaults.set(kidsModePlayerId, forKey: Keys.kidsModePlayerId)
            } else {
                defaults.removeObject(forKey: Keys.kidsModePlayerId)
            }
        }
    }

    /// Which favorites feed the carousel, in section order. Never empty — see
    /// `KidsMediaType.toggling`.
    var kidsModeMediaTypes: [KidsMediaType] {
        didSet { defaults.set(KidsMediaType.encode(kidsModeMediaTypes), forKey: Keys.kidsModeMediaTypes) }
    }

    // MARK: - View mode

    /// Grid or list for the library category of `mediaTypeName` (a Kotlin `MediaType.name`).
    func viewMode(forMediaType mediaTypeName: String) -> ViewMode {
        ViewMode(rawValue: defaults.string(forKey: Keys.viewMode(mediaTypeName)) ?? "") ?? .grid
    }

    func setViewMode(_ mode: ViewMode, forMediaType mediaTypeName: String) {
        defaults.set(mode.rawValue, forKey: Keys.viewMode(mediaTypeName))
    }

    // MARK: - Storage

    private enum Keys {
        static let theme = "theme"
        static let liveActivityVisibility = "live_activity_visibility"
        static let homeRows = "home_rows_config"
        static let libraryCategories = "library_tabs_config"
        static let kidsModeEnabled = "kids_mode_enabled"
        static let kidsModePlayerId = "kids_mode_player_id"
        static let kidsModeMediaTypes = "kids_mode_media_types"
        static func viewMode(_ mediaTypeName: String) -> String { "view_mode_\(mediaTypeName)" }
    }

    private static func decodeHomeRows(_ raw: String?) -> [HomeRowPref] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([HomeRowPref].self, from: data)) ?? []
    }

    private static func decodeLibraryCategories(_ raw: String?) -> [LibraryCategoryPref] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return LibraryCategoryPref(name: String(parts[0]), enabled: parts[1] == "1")
        }
    }

    /// Re-arms `withObservationTracking` after each change so the callback keeps firing. The
    /// tracking closure runs off the main actor; the hop back is explicit.
    private func observe<Value: Equatable>(
        _ keyPath: KeyPath<AppPreferences, Value>,
        _ onChange: @escaping @MainActor (Value) -> Void
    ) {
        withObservationTracking {
            _ = self[keyPath: keyPath]
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                onChange(self[keyPath: keyPath])
                self.observe(keyPath, onChange)
            }
        }
    }
}
