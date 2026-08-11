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

    private var displayValue: Float { dragValue ?? pendingValue ?? volume ?? 0 }

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
                    set: { dragValue = Float($0) }
                ),
                range: 0...100,
                // Five points per VoiceOver step: 20 stops across the range, which is about as
                // fine as a volume control is worth making without turning it into a chore.
                step: 5,
                valueDescription: { (($0) / 100).formatted(.percent.precision(.fractionLength(0))) },
                onEditingChanged: { editing in
                    // Plain assignment, with the animation scoped to the glyphs below.
                    //
                    // Wrapping this in `withAnimation` made the volume bar visibly slower to
                    // swell than the seek bar. The transaction is open while this state change
                    // re-renders the whole subtree — `CapsuleSlider` included — so the bar's own
                    // spring was being overridden by the caller's, on a value the bar knows
                    // nothing about. The seek bar never had the problem because its parent
                    // animates with a scoped `.animation(_:value:)` instead.
                    isAdjusting = editing
                    guard !editing, let level = dragValue else { return }
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
        // Any change to `volume` is the round trip closing: either the server took our value, or
        // something else moved it and that reading should win. Either way stop overriding.
        .onChange(of: volume) { _, _ in pendingValue = nil }
        // Backstop. A server that clamps our value to what it already had emits no change at all,
        // and the fill would sit on a level the player never reached until the next event.
        .task(id: pendingValue) {
            guard pendingValue != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pendingValue = nil
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if canMute {
            Button(action: onMuteToggle) {
                icon(muted: isMuted)
                    // Pins the tappable area to the glyph itself. Without it the button's hit
                    // region reaches past its label into the rest of the row — the same reason
                    // `.borderless` is a hazard in list rows — and the slider's drag then had to
                    // wait for the button's gesture to fail before it could start. That wait is
                    // the delay: a tap on the bar resolved too late to look like a response, and
                    // only a drag, which the button loses outright, felt immediate.
                    .contentShape(.rect)
            }
            // `.plain` rather than `.borderless` for the same reason.
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
