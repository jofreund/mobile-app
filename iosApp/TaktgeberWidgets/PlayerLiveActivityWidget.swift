import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen banner + Dynamic Island for the selected player. Pure presentation over
/// `PlayerActivityAttributes.ContentState`; the play/pause button fires `PlayerPlayPauseIntent`,
/// which executes in the app's process (see PlayerActivityShared.swift).
///
/// Stale rendering: once `staleDate` passes without an update (app suspended, state changed from
/// another client), `context.isStale` flips — the transport glyph is then dimmed and the play
/// state deliberately not asserted. The button stays live either way; tapping it wakes the app
/// process, which re-syncs and republishes real state.
struct PlayerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            LockScreenPlayerView(context: context)
                .widgetURL(URL(string: "musicassistant://app/players"))
        } dynamicIsland: { context in
            DynamicIsland {
                // One full-width row in the bottom region instead of leading/center/trailing:
                // the side regions size to their own content and top-align against a taller
                // center, and no frame trickery reliably re-centers them (tried, shipped,
                // looked wrong on device). The bottom region hands full layout control to the
                // same row the lock screen uses, so the two surfaces stay identical — speaker
                // icon included, artwork and button HStack-centered on the three-line block.
                DynamicIslandExpandedRegion(.bottom) {
                    // Asymmetric on purpose: the island's sensor area already pads the top of
                    // the card by ~28pt, so the bottom needs the bigger inset for the row to
                    // sit with equal breathing room above and below. Tuned by eye on device.
                    PlayerActivityRow(context: context)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                        .padding(.bottom, 20)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .opacity(context.isStale ? 0.5 : 1)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}

private struct LockScreenPlayerView: View {
    let context: ActivityViewContext<PlayerActivityAttributes>

    var body: some View {
        PlayerActivityRow(context: context)
            .padding(14)
            // The system can hand the banner more height than the content needs; without this
            // the row hugs the top edge and the extra space pools below. Fill and center.
            .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// The one content row both presentations share — lock screen banner and expanded island
/// bottom region. The HStack's default center alignment is what keeps artwork and transport
/// button vertically centered on the three-line text block.
private struct PlayerActivityRow: View {
    let context: ActivityViewContext<PlayerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            PlayerArtworkView(fileName: context.state.artworkFileName)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = context.state.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker")
                        .font(.caption2)
                    Text(context.state.playerName)
                        .font(.caption)
                        .lineLimit(1)
                    if context.isStale {
                        Text("· ?")
                            .font(.caption)
                    }
                }
                // .tertiary is illegible on the activity's dark material — user-reported.
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PlayPauseButton(context: context)
        }
    }
}

private struct PlayPauseButton: View {
    let context: ActivityViewContext<PlayerActivityAttributes>

    var body: some View {
        Button(intent: PlayerPlayPauseIntent(playerId: context.state.playerId)) {
            Image(systemName: glyph)
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(context.isStale ? 0.6 : 1)
    }

    /// While stale the shown play state is a guess — fall back to the neutral toggle glyph
    /// rather than confidently showing the wrong half of play/pause.
    private var glyph: String {
        if context.isStale { return "playpause.fill" }
        return context.state.isPlaying ? "pause.fill" : "play.fill"
    }
}

private struct PlayerArtworkView: View {
    let fileName: String?

    var body: some View {
        Group {
            if let image = loadImage() {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func loadImage() -> UIImage? {
        guard let fileName,
              let url = PlayerActivityArtworkStore.url(for: fileName)
        else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
