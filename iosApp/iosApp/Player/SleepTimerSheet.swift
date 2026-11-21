import SwiftUI
import MusicAssistantKit

/// Picking a server-side sleep timer for the current player.
///
/// The timer itself lives on the server (`players/sleep_timer/set`) — it counts down and stops
/// playback whether this app is foregrounded, suspended, or gone, which is the only reliable
/// shape for a remote-control app that produces no audio of its own. Everything here is
/// display: the fixed duration options mirror upstream's `SleepTimerDialog`, and the countdown
/// is derived from the expiry timestamp the server reports on every `player_updated`.
///
/// From schema 105 the server can also stop at the end of the current item or chapter
/// (upstream #1384). Those rows follow the durations, only while the server would accept them
/// (`sleepTimerEndModes`), named after what plays: "End of track", "End of episode", ...
/// Such a timer's expiry is the server's estimate, and it reports none while paused, so the
/// active section names the end rather than relying on a countdown.
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
                // A countdown still in the future, or an end-of-content timer — which reports
                // no expiry while paused but is still set.
                if countdownExpiry != nil || player.sleepTimerEndMode != nil {
                    activeTimerSection
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
                if !endModes.isEmpty {
                    Section {
                        ForEach(endModes, id: \.self) { mode in
                            Button {
                                store.setSleepTimer(id: player.id, mode: mode)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(sleepTimerEndLabel(mode: mode, item: player.trackItem))
                                    Spacer()
                                    if mode == player.sleepTimerEndMode {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(mode == player.sleepTimerEndMode ? [.isSelected] : [])
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

    /// Gated on "still in the future" so an expired-but-not-yet-echoed timestamp reads as no
    /// timer. The server clears the field itself on expiry; until that `player_updated` lands
    /// the countdown just stays hidden rather than showing a frozen 0:00.
    private var countdownExpiry: Double? {
        guard let expiresAt = player.sleepTimerExpiresAt,
              expiresAt > Date.now.timeIntervalSince1970 else { return nil }
        return expiresAt
    }

    /// Older servers (schema < 105) reject the `mode` argument, so they get no end rows.
    private var endModes: [SleepTimerMode] {
        KmpHelper.shared.isSleepTimerModesSupported() ? player.sleepTimerEndModes : []
    }

    private var activeTimerSection: some View {
        Section {
            LabeledContent {
                // Self-updating countdown — no timer loop of our own. Display only: the
                // authoritative countdown is the server's, and a device clock that disagrees
                // with the server's shows a skewed remaining time but stops at the right moment.
                // An end-of-content timer has none while paused; its label says when it stops.
                if let expiresAt = countdownExpiry {
                    Text(
                        timerInterval: Date.now...Date(timeIntervalSince1970: expiresAt),
                        countsDown: true
                    )
                    .monospacedDigit()
                }
            } label: {
                if let endMode = player.sleepTimerEndMode {
                    Text(sleepTimerEndLabel(mode: endMode, item: player.trackItem))
                } else {
                    Text(String(localized: "sleep_timer_stops_in"))
                }
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

/// The name of an end-of-content timer, after the type of what plays, like the web frontend
/// (upstream `sleepTimerEndLabel`).
func sleepTimerEndLabel(mode: SleepTimerMode, item: AppMediaItem?) -> String {
    if mode == SleepTimerMode.endOfChapter { return String(localized: "sleep_timer_end_of_chapter") }
    if item is Track { return String(localized: "sleep_timer_end_of_track") }
    if item is PodcastEpisode { return String(localized: "sleep_timer_end_of_episode") }
    if item is Audiobook { return String(localized: "sleep_timer_end_of_audiobook") }
    return String(localized: "sleep_timer_end_of_item")
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
