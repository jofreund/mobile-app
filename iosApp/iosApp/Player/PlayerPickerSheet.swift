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
/// which speakers is this coming out of — and because a sheet has a top bar to put it in, where
/// the bottom row it used to sit on did not.
struct PlayerPickerSheet: View {

    /// The player currently being driven. Passed as a value, not looked up by id, for the reason
    /// spelled out in `GroupSettingsView`: an id string never changes, so SwiftUI would have
    /// nothing to diff and would keep showing a stale group state after a join or leave.
    let player: PlayerBarItemView
    var store: PlayerBarStore

    @State private var showGroupSettings = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
            .navigationTitle(String(localized: "players_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_done")) { dismiss() }
                }
                // Only when there is something to manage — a bound group, or at least one
                // groupable candidate. Same rule as the button this replaces.
                if player.isGrouped || !player.groupMembers.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showGroupSettings = true } label: {
                            Image(systemName: "hifispeaker.2")
                        }
                        .accessibilityLabel(String(localized: "players_group_settings"))
                    }
                }
            }
            .sheet(isPresented: $showGroupSettings) {
                GroupSettingsView(player: player, store: store)
                    .presentationDetents([.medium, .large])
            }
        }
        .presentationDetents([.medium, .large])
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
