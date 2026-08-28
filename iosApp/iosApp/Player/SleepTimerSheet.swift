import SwiftUI

/// Picking a server-side sleep timer for the current player.
///
/// The timer itself lives on the server (`players/sleep_timer/set`) — it counts down and stops
/// playback whether this app is foregrounded, suspended, or gone, which is the only reliable
/// shape for a remote-control app that produces no audio of its own. Everything here is
/// display: the fixed duration options mirror upstream's `SleepTimerDialog`, and the countdown
/// is derived from the expiry timestamp the server reports on every `player_updated`.
///
/// A sheet rather than a menu for the same reason as `PlayerPickerSheet`: real rows, a title,
/// and room for the countdown/clear section to appear and disappear without the layout jumping.
struct SleepTimerSheet: View {

    /// Passed as a value, not looked up by id — see `GroupSettingsContent`'s doc: an id string
    /// never changes, so SwiftUI would have nothing to diff when the timer state updates.
    let player: PlayerBarItemView
    var store: PlayerBarStore

    @Environment(\.dismiss) private var dismiss

    /// Upstream's fixed option set, in seconds: 15/30/45 min, 1 h, 2 h.
    private static let options: [Int] = [15, 30, 45, 60, 120].map { $0 * 60 }

    var body: some View {
        NavigationStack {
            List {
                // Gated on "still in the future" so an expired-but-not-yet-echoed timestamp
                // reads as no timer. The server clears the field itself on expiry; until that
                // `player_updated` lands this section just stays hidden rather than showing a
                // frozen 0:00.
                if let expiresAt = player.sleepTimerExpiresAt,
                   expiresAt > Date.now.timeIntervalSince1970 {
                    activeTimerSection(expiresAt: expiresAt)
                }
                Section {
                    ForEach(Self.options, id: \.self) { seconds in
                        Button {
                            store.setSleepTimer(id: player.id, seconds: seconds)
                            dismiss()
                        } label: {
                            Text(sleepTimerOptionLabel(seconds: seconds))
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "player_sleep_timer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func activeTimerSection(expiresAt: Double) -> some View {
        Section {
            LabeledContent {
                // Self-updating countdown — no timer loop of our own. Display only: the
                // authoritative countdown is the server's, and a device clock that disagrees
                // with the server's shows a skewed remaining time but stops at the right moment.
                Text(
                    timerInterval: Date.now...Date(timeIntervalSince1970: expiresAt),
                    countsDown: true
                )
                .monospacedDigit()
            } label: {
                Text(String(localized: "sleep_timer_stops_in"))
            }

            Button(role: .destructive) {
                store.clearSleepTimer(id: player.id)
                dismiss()
            } label: {
                Text(String(localized: "sleep_timer_clear"))
            }
        }
    }
}

/// "15 minutes" / "1 hour" / "2 hours" — port of upstream `SleepTimerDialog`'s `optionLabel`.
/// A pure free function so it stays trivially unit-testable.
func sleepTimerOptionLabel(seconds: Int) -> String {
    let minutes = seconds / 60
    if minutes < 60 {
        return String(format: String(localized: "sleep_timer_minutes"), minutes)
    }
    let hours = minutes / 60
    return hours == 1
        ? String(localized: "sleep_timer_hour")
        : String(format: String(localized: "sleep_timer_hours"), hours)
}
