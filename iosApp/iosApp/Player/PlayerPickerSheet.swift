import SwiftUI

/// Choosing which player the expanded view is driving.
///
/// A sheet rather than a menu. A menu gives each row exactly one image slot, and the checkmark
/// owns it — so device icons had to be left out, or selection had to be shown some other way
/// (it was a "Current" section for a while). A sheet is a real layout: icon, name and checkmark
/// each get their own place, rows are full width and comfortably tappable, and the list can grow
/// past the handful of entries a menu stays readable at.
///
/// Group settings rides in the toolbar because it answers the same question the list does —
/// which speakers is this coming out of. It *replaces* the list rather than opening over it: two
/// stacked sheets for two views of the same question is a lot of chrome, and swapping content
/// under one title keeps the toggle reversible in a single tap. The button carries the selected
/// state so it is obvious which of the two is showing.
struct PlayerPickerSheet: View {

    /// The player currently being driven. Passed as a value, not looked up by id, for the reason
    /// spelled out in `GroupSettingsContent`: an id string never changes, so SwiftUI would have
    /// nothing to diff and would keep showing a stale group state after a join or leave.
    let player: PlayerBarItemView
    var store: PlayerBarStore

    /// Which of the two the sheet is showing. Not a separate presentation — see the type doc.
    private enum Mode { case players, group }

    @State private var mode: Mode = .players
    @Environment(\.dismiss) private var dismiss

    /// Only when there is something to manage — a bound group, or at least one groupable
    /// candidate. Same rule as the button this replaces.
    private var canManageGroup: Bool { player.isGrouped || !player.groupMembers.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .players: playerList
                case .group: GroupSettingsContent(player: player, store: store)
                }
            }
            .navigationTitle(String(localized: mode == .group ? "players_group_settings" : "players_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_done")) { dismiss() }
                }
                if canManageGroup {
                    ToolbarItem(placement: .topBarTrailing) { groupToggle }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // A player leaving its last group while the group view is open would otherwise strand the
        // sheet on a panel with nothing in it and no button left to leave by.
        .onChange(of: canManageGroup) { _, canManage in
            if !canManage { mode = .players }
        }
    }

    private var playerList: some View {
        List {
            ForEach(store.players) { candidate in
                PlayerPickerRow(
                    candidate: candidate,
                    isCurrent: candidate.id == player.id
                ) {
                    store.selectPlayer(id: candidate.id)
                    dismiss()
                }
            }
        }
    }

    private var groupToggle: some View {
        Button {
            mode = mode == .group ? .players : .group
        } label: {
            // Filled and tinted while its panel is showing, outlined and quiet otherwise — the
            // same on/off vocabulary the expanded player's icon row (queue/favorite/timer) uses.
            Image(systemName: mode == .group ? "hifispeaker.2.fill" : "hifispeaker.2")
                .foregroundStyle(mode == .group ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel(String(localized: "players_group_settings"))
        .accessibilityAddTraits(mode == .group ? [.isSelected] : [])
    }
}

private struct PlayerPickerRow: View {

    let candidate: PlayerBarItemView
    let isCurrent: Bool
    let onSelect: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: candidate.symbolName)
                    // Fixed width so names line up down the list rather than stepping in and out
                    // with each glyph's own width.
                    .frame(width: 24)
                    .foregroundStyle(.secondary)

                Text(candidate.name)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Same trailing slot the Compose player dialog used for its NowPlayingIcon —
                // "which of these is making sound right now", independent of which one the
                // checkmark says this screen is driving.
                if candidate.isPlaying {
                    NowPlayingIndicator()
                }

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressReportingButtonStyle { isPressed = $0 })
        .pressHighlight(isPressed)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
