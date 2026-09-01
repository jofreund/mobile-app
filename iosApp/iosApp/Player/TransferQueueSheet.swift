import SwiftUI

/// Picking the player that should take over this queue — `player_queues/transfer` behind the
/// expanded player's ⋯ menu.
///
/// A sheet rather than a submenu inside that menu, for the reason `PlayerPickerSheet` spells
/// out: a menu row has one image slot, and a nested menu is two levels of chrome over a list
/// that can be long. Rows borrow that picker's vocabulary — icon column, name, a
/// `NowPlayingIndicator` for a target already making sound — minus the checkmark, since nothing
/// in this list is "selected"; each row is an action.
///
/// Tapping a row transfers and dismisses, with no confirmation step: the same immediate
/// dispatch the queue's own row deletion uses, and it undoes by transferring back.
struct TransferQueueSheet: View {

    /// The player whose queue is moving. Passed as a value, not looked up by id — same reason
    /// `PlayerPickerSheet` gives: an id never changes, so SwiftUI would have nothing to diff.
    let player: PlayerBarItemView
    var store: PlayerBarStore

    @Environment(\.dismiss) private var dismiss

    private var candidates: [PlayerBarItemView] {
        TransferQueueTargets.candidates(from: store.players, source: player)
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        String(localized: "queue_no_other_players"),
                        systemImage: "hifispeaker"
                    )
                } else {
                    List {
                        ForEach(candidates) { candidate in
                            TransferQueueRow(candidate: candidate) { transfer(to: candidate) }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "queue_transfer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func transfer(to target: PlayerBarItemView) {
        // Both sides are addressed by queue id; `queueId` is nil only for a player with no
        // queue at all, which is why the menu entry is disabled in that case and why every
        // candidate has one.
        guard let sourceQueueId = player.queueId, let targetQueueId = target.queueId else { return }
        store.transferQueue(
            sourceQueueId: sourceQueueId,
            targetQueueId: targetQueueId,
            // Keep playing music that was playing, leave a paused queue paused.
            autoplay: player.isPlaying
        )
        // The queue and the sound have moved; the expanded player follows them rather than
        // staying on a source that is now empty.
        store.selectPlayer(id: target.id)
        dismiss()
    }
}

private struct TransferQueueRow: View {

    let candidate: PlayerBarItemView
    let onSelect: () -> Void

    @State private var isPressed = false

    /// Scales with the icon, so names still line up at accessibility text sizes.
    @ScaledMetric private var iconColumn: CGFloat = 24

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                PlayerIcon(candidate.iconId)
                    .frame(width: iconColumn)
                    .foregroundStyle(.secondary)

                Text(candidate.name)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Worth flagging here more than in the player picker: this target is playing
                // something of its own, and transferring will replace it.
                if candidate.isPlaying {
                    NowPlayingIndicator()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressReportingButtonStyle { isPressed = $0 })
        .pressHighlight(isPressed)
    }
}
