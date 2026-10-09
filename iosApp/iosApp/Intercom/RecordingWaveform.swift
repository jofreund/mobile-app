import SwiftUI

/// A live picture of what the microphone is hearing, shown in the middle of
/// the pop-over while a tile is held.
///
/// Bars scroll from right to left, the newest sample on the right, mirrored
/// about the centre line so the shape reads as a waveform rather than as a bar
/// chart.
///
/// Two things keep it smooth. It reads the recorder itself instead of taking a
/// level down through the card: the level changes 25 times a second, and a
/// view that *passes* it makes every view above the waveform — the pop-over's
/// glass included — redraw just as often. And it draws into a ``Canvas``
/// rather than laying out a row of bars, so a new sample is one repaint
/// instead of 36 animating frames.
struct RecordingWaveform: View {
    /// The live meter. `nil` in previews and other places without one, which
    /// draws the resting line.
    let recorder: IntercomRecorder?
    /// Whether the mic is actually capturing yet. The waveform is shown
    /// throughout `.arming` too — see `IntercomCard.showsWaveform` — while the
    /// pop-over is still growing and no sample is real yet; drawing that flat
    /// line in the recording colour would read as "already hearing silence"
    /// rather than "about to listen".
    let isRecording: Bool
    /// Drawn in red while releasing would cancel, matching the rest of the
    /// card. Takes precedence over `isRecording`: cancelling only exists once
    /// a press can be released, so it is never true before recording starts.
    let isCancelling: Bool
    /// Bar width and spacing double for the pop-over, like everything else on
    /// the card.
    let isExpanded: Bool
    /// Only shown in previews, where there is no recorder to read.
    var sampleOverride: [Double]?

    private var barWidth: CGFloat { isExpanded ? 6 : 3 }
    private var spacing: CGFloat { isExpanded ? 4 : 2 }
    /// Kept modest: the pop-over is a fixed 2× the tile, and a taller waveform
    /// would push the action row out of a card whose name wraps to two lines.
    private var height: CGFloat { isExpanded ? 56 : 28 }

    var body: some View {
        // Read here, in the body, and handed to the canvas as a plain array:
        // reading the recorder inside the draw closure would leave the view
        // out of the observation that is supposed to redraw it.
        let samples = sampleOverride ?? recorder?.levels ?? IntercomRecorder.silentHistory
        let colour: Color = if isCancelling {
            .cancel
        } else if isRecording {
            .accentColor
        } else {
            Color(.systemGray3)
        }
        let bar = barWidth
        let gap = spacing

        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            Self.draw(samples, in: &context, size: size, barWidth: bar, spacing: gap, colour: colour)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private static func draw(
        _ samples: [Double],
        in context: inout GraphicsContext,
        size: CGSize,
        barWidth: CGFloat,
        spacing: CGFloat,
        colour: Color
    ) {
        guard samples.count > 1 else { return }
        // The bars share whatever the card has: on a narrow phone they get
        // thinner rather than being clipped.
        let step = min(barWidth + spacing, size.width / CGFloat(samples.count))
        let width = min(barWidth, max(1, step - spacing))
        // Right-aligned, so the newest sample sits at the trailing edge
        // whatever the card's width rounds the bars to.
        let firstX = size.width - CGFloat(samples.count) * step + (step - width) / 2

        // All the bars in one path, filled once. A fill per bar is
        // thirty-six shadings to resolve and thirty-six draw calls per tick,
        // twenty-five times a second, under a pane of glass that has to
        // recomposite with every one of them.
        var bars = Path()
        for (index, sample) in samples.enumerated() {
            let barHeight = width + (size.height - width) * CGFloat(min(max(sample, 0), 1))
            bars.addRoundedRect(
                in: CGRect(
                    x: firstX + CGFloat(index) * step,
                    y: (size.height - barHeight) / 2,
                    width: width,
                    height: barHeight
                ),
                cornerSize: CGSize(width: width / 2, height: width / 2),
                style: .continuous
            )
        }

        // Older samples fade out towards the left, so the eye is drawn to the
        // syllable being spoken right now. One gradient across the row rather
        // than an opacity per bar: it is anchored on the first and the last
        // bar's centre, which is where the per-bar values sat, and at six
        // points wide no bar is broad enough to show the ramp across itself.
        context.fill(
            bars,
            with: .linearGradient(
                Gradient(colors: [colour.opacity(0.35), colour]),
                startPoint: CGPoint(x: firstX + width / 2, y: 0),
                endPoint: CGPoint(x: firstX + CGFloat(samples.count - 1) * step + width / 2, y: 0)
            )
        )
    }
}

#Preview {
    /// A plausible frozen frame of speech.
    let speech = (0..<IntercomRecorder.levelHistoryCount).map { index in
        0.15 + 0.55 * abs(sin(Double(index) / 3.2)) * Double(index) / Double(IntercomRecorder.levelHistoryCount)
    }
    return VStack(spacing: 32) {
        RecordingWaveform(recorder: nil, isRecording: false, isCancelling: false, isExpanded: true)
        RecordingWaveform(recorder: nil, isRecording: true, isCancelling: false, isExpanded: true, sampleOverride: speech)
        RecordingWaveform(recorder: nil, isRecording: true, isCancelling: true, isExpanded: true, sampleOverride: speech)
        RecordingWaveform(recorder: nil, isRecording: true, isCancelling: false, isExpanded: true)
    }
    .padding()
    .background { Backdrop() }
}
