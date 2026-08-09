import SwiftUI

/// The list of players to switch between, shared by both places that offer the choice: the
/// expanded player's header and a long press on the mini player. They had been built
/// separately — a custom `List` in a popover on one side, a system menu on the other — which
/// meant two different looks for one decision, down to which side the checkmark sat on.
///
/// Written as menu content, so it renders as a system menu in both. That settles the styling
/// question by construction rather than by matching one to the other, and it drops the popover's
/// fixed height, which had been cutting the list off partway down with more players below.
struct PlayerPickerMenu: View {

    let store: PlayerBarStore
    /// Marked with a checkmark. The expanded player passes the page's own player, which is the
    /// selected one by the time its header is on screen.
    let currentId: String

    var body: some View {
        Section(String(localized: "players_title")) {
            ForEach(store.players) { candidate in
                Button {
                    store.selectPlayer(id: candidate.id)
                } label: {
                    // A menu button renders its label's image where a checkmark goes, so this
                    // is how "currently selected" is spelled in a menu — leading, not trailing.
                    if candidate.id == currentId {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
        }
    }
}
