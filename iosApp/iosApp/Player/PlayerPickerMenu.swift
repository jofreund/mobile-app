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
    /// The player to mark as current.
    let currentId: String

    var body: some View {
        // Still a menu, and still constrained by one, because this is the mini player's
        // *context* menu — `contextMenu` takes menu content, so it cannot host the list
        // `PlayerPickerSheet` uses in the expanded player. The two differ for that reason, not by
        // oversight.
        //
        // Selection is shown by grouping, not by a checkmark.
        //
        // A menu button has exactly one image slot and the checkmark owns it, so a row cannot
        // carry both a checkmark and its device icon. Interpolating the icon into the title text
        // instead was tried and silently renders nothing — menu rows are UIKit, and an image
        // attachment in the title is not something they draw.
        //
        // So the checkmark goes, and the current player gets its own section. Every row keeps its
        // icon, which was the point, and "which one am I on" is answered by a heading rather than
        // by a mark the eye has to hunt for.
        Section(String(localized: "players_current_section")) {
            if let current = store.players.first(where: { $0.id == currentId }) {
                row(for: current)
            }
        }

        Section(String(localized: "players_title")) {
            ForEach(store.players.filter { $0.id != currentId }) { candidate in
                row(for: candidate)
            }
        }
    }

    private func row(for candidate: PlayerBarItemView) -> some View {
        Button {
            store.selectPlayer(id: candidate.id)
        } label: {
            Label(candidate.name, systemImage: candidate.symbolName)
        }
    }
}
