import SwiftUI

/// The play/pause glyph, at a width that doesn't change when it toggles.
///
/// `play.fill` and `pause.fill` are not the same width, so swapping them resizes whatever
/// contains them. In the expanded player's centred transport row that pushed every other control
/// sideways by half the difference on each tap; in the mini player it made the button itself
/// twitch against the trailing skip control. Both read as the layout flinching every time
/// playback is toggled.
///
/// Reserving the union of the two glyphs — both laid out hidden, so the stack takes the larger
/// width and height — fixes it without a hard-coded frame, which would need revisiting whenever
/// the font size changes or SF Symbols redraws either glyph. The visible image is drawn on top.
///
/// Takes no font of its own: callers set one with `.font`, which the hidden pair inherit too, so
/// the reserved size always matches the size actually being drawn.
struct PlayPauseIcon: View {

    let isPlaying: Bool

    init(isPlaying: Bool) { self.isPlaying = isPlaying }

    var body: some View {
        ZStack {
            Image(systemName: "play.fill").hidden()
            Image(systemName: "pause.fill").hidden()
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        }
    }
}
