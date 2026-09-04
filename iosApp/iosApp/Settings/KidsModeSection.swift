import SwiftUI
import MusicAssistantKit

/// Kids mode, set up by the parent: the on/off switch, which player the room's view drives, and
/// which favorites feed its carousel. Binds straight to `AppPreferences`; `AppShellRootView`
/// reads the same flag and swaps the shell the moment it changes, so closing Settings lands on
/// the kids view with nothing else to do.
///
/// Two sections rather than one: the type toggles are a list of their own, and a header over
/// them says what the list is for without a sub-screen.
struct KidsModeSection: View {

    private let preferences = AppPreferences.shared

    /// Read once, on appear. A synchronous read of the bar projection is enough for a picker's
    /// options — this is not a live display, and a player that joins while Settings is open is
    /// one reopen away. A stored id that is not in the list right now is kept as an option
    /// under its raw id, so the picker still shows what is set rather than nothing.
    @State private var players: [KidsPlayerOption] = []

    var body: some View {
        Group {
            Section {
                Toggle(String(localized: "kids_mode_enable"), isOn: enabledBinding)
                Picker(String(localized: "kids_mode_player"), selection: playerBinding) {
                    Text(String(localized: "kids_mode_player_selected")).tag(String?.none)
                    ForEach(players) { player in
                        Text(player.name).tag(String?.some(player.id))
                    }
                }
            } header: {
                Text(String(localized: "kids_mode"))
            } footer: {
                Text(String(localized: "kids_mode_explanation"))
            }

            Section(String(localized: "kids_mode_media_types")) {
                ForEach(KidsMediaType.allCases) { type in
                    Toggle(
                        String(localized: String.LocalizationValue(type.localizationKey)),
                        isOn: typeBinding(type)
                    )
                }
            }
        }
        .onAppear { players = Self.currentPlayers(storedId: preferences.kidsModePlayerId) }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.kidsModeEnabled },
            set: { preferences.kidsModeEnabled = $0 }
        )
    }

    private var playerBinding: Binding<String?> {
        Binding(
            get: { preferences.kidsModePlayerId },
            set: { preferences.kidsModePlayerId = $0 }
        )
    }

    private func typeBinding(_ type: KidsMediaType) -> Binding<Bool> {
        Binding(
            get: { preferences.kidsModeMediaTypes.contains(type) },
            set: { on in
                preferences.kidsModeMediaTypes = KidsMediaType.toggling(type, on: on, in: preferences.kidsModeMediaTypes)
            }
        )
    }

    // MARK: - Players

    private static func currentPlayers(storedId: String?) -> [KidsPlayerOption] {
        let live = (KmpHelper.shared.playerBarState.value as? PlayerBarState.Data)?.players ?? []
        var options = live.map { KidsPlayerOption(id: $0.playerId, name: $0.name) }
        if let storedId, !options.contains(where: { $0.id == storedId }) {
            options.append(KidsPlayerOption(id: storedId, name: storedId))
        }
        return options
    }
}

private struct KidsPlayerOption: Identifiable, Equatable {
    let id: String
    let name: String
}
