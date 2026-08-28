import SwiftUI

/// The one volume control, shared by the expanded player's inline slider and every row of the
/// group settings sheet — they had grown separate copies that drifted apart in spacing, icon and
/// whether they showed a number.
///
/// Styled after Apple Music: a quiet-speaker glyph on the left, a loud one on the right, and no
/// numeric readout. The value is legible from the track itself, and a percentage invites reading
/// a slider as a number to hit rather than a level to feel.
///
/// The left glyph doubles as the mute toggle where the player supports muting ([canMute]),
/// switching to a struck-through speaker when muted. That keeps mute reachable without adding a
/// third control to a row that is meant to read as two icons and a track. Where a player can't
/// mute, the same glyph stays as a plain indicator.
struct VolumeSlider: View {

    /// Already 0...100 — `Player.currentVolume`'s own scale, which Compose's slider used
    /// directly too. Nothing here divides or multiplies by 100.
    let volume: Float?
    let isMuted: Bool
    let canMute: Bool
    let enabled: Bool
    let onMuteToggle: () -> Void
    let onVolumeSet: (Float) -> Void

    /// Held locally so the fill tracks the finger, then handed over on release. Server echoes
    /// arriving mid-drag would otherwise yank it back.
    @State private var dragValue: Float?

    /// The value just released, held until the server echoes it back.
    ///
    /// Without this the fill snapped to the *old* level for the round trip and then jumped to the
    /// new one — `volume` is still the pre-change value at the moment the finger lifts, so
    /// dropping `dragValue` right away falls back to it. The same reason the seek bar keeps a
    /// `releasedSeekPosition`.
    @State private var pendingValue: Float?

    /// Mirrors `CapsuleSlider`'s own swell so the glyphs can move aside for it.
    @State private var isAdjusting = false

    /// The last level actually sent during this drag, and when — the throttle for `sendLive`.
    @State private var lastLiveSend: (level: Float, at: Date)?

    private var displayValue: Float { dragValue ?? pendingValue ?? volume ?? 0 }

    /// At most one live send per this interval while dragging. Frequent enough to hear the level
    /// follow the finger, sparse enough not to flood a player whose volume command is slow.
    private static let liveSendInterval: TimeInterval = 0.2
    /// And only when the level has moved at least this far since the last send — matches the
    /// slider's own 5-point VoiceOver step, so a resting finger sends nothing.
    private static let liveSendMinDelta: Float = 5

    var body: some View {
        HStack(spacing: 14) {
            leadingIcon
                // The bar grows into the gap on both sides; the glyphs give it a little room
                // rather than being crowded, which is what Apple Music does here too.
                .offset(x: isAdjusting ? -4 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAdjusting)

            CapsuleSlider(
                value: Binding(
                    get: { Double(displayValue) },
                    set: {
                        dragValue = Float($0)
                        // Throttled live send, so the audio follows the finger instead of only
                        // changing on release. The final release value still goes out below.
                        sendLive()
                    }
                ),
                range: 0...100,
                // Five points per VoiceOver step: 20 stops across the range, which is about as
                // fine as a volume control is worth making without turning it into a chore.
                step: 5,
                valueDescription: { (($0) / 100).formatted(.percent.precision(.fractionLength(0))) },
                onEditingChanged: { editing in
                    // Plain assignment, with the animation scoped to the glyphs below, so the
                    // caller's transaction cannot re-time `CapsuleSlider`'s own spring. This was
                    // once believed to be why the bar swelled late; it was not — the seek bar's
                    // caller uses `withAnimation` and has never been slow. Kept because scoping
                    // an animation to the views it applies to is right regardless.
                    isAdjusting = editing
                    if editing {
                        // Fresh throttle per drag: the first movement sends immediately.
                        lastLiveSend = nil
                        return
                    }
                    lastLiveSend = nil
                    guard let level = dragValue else { return }
                    // Order matters: hand over to `pendingValue` before clearing `dragValue`, or
                    // `displayValue` falls through to the stale `volume` for a frame.
                    pendingValue = level
                    onVolumeSet(level)
                    dragValue = nil
                },
                // Less than the seek bar's: that one spans the full width with nothing beside
                // it, while this has to grow into a 14pt gap without touching the glyphs.
                activeOverhang: 6
            )
            .disabled(!enabled)
            .accessibilityLabel(String(localized: "cd_volume"))

            Image(systemName: "speaker.wave.3.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Decorative: it labels the loud end of a slider VoiceOver already describes.
                .accessibilityHidden(true)
                .offset(x: isAdjusting ? 4 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAdjusting)
        }
        .opacity(enabled ? 1 : 0.4)
        // A change to `volume` near the released value is the round trip closing — stop
        // overriding. Not *any* change any more: live sends during the drag mean the server can
        // still be echoing intermediate levels when the finger lifts, and dropping the latch on
        // one of those snapped the fill backwards for a beat. A genuinely different reading
        // (something else moved the volume) waits out the 3s backstop below instead.
        .onChange(of: volume) { _, newValue in
            guard let pending = pendingValue, let newValue else { return }
            if abs(newValue - pending) < Self.liveSendMinDelta { pendingValue = nil }
        }
        // Backstop. A server that clamps our value to what it already had emits no change at all,
        // and the fill would sit on a level the player never reached until the next event.
        .task(id: pendingValue) {
            guard pendingValue != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pendingValue = nil
        }
    }

    /// Sends the in-drag level when it has moved far enough since the last send and the throttle
    /// window has passed. Skipped entirely outside a drag (`dragValue` nil). Deliberately does
    /// not touch `pendingValue`: `dragValue` still owns the fill until release, so server echoes
    /// of these intermediate levels can't yank it around.
    private func sendLive() {
        guard let level = dragValue else { return }
        if let last = lastLiveSend {
            guard Date().timeIntervalSince(last.at) >= Self.liveSendInterval,
                  abs(level - last.level) >= Self.liveSendMinDelta else { return }
        }
        lastLiveSend = (level, Date())
        onVolumeSet(level)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if canMute {
            Button(action: onMuteToggle) {
                icon(muted: isMuted)
                    // Pins the tappable area to the glyph. `.borderless` used to let the button's
                    // hit region reach into the rest of the row — the same property that makes it
                    // a hazard in list rows.
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(String(localized: isMuted ? "cd_unmute" : "cd_mute"))
        } else {
            icon(muted: false)
                .accessibilityHidden(true)
        }
    }

    private func icon(muted: Bool) -> some View {
        Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
