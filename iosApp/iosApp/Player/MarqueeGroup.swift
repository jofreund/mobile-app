import SwiftUI

/// The clock a group of `MarqueeText`s scroll to: when the current loop began, and how long the
/// longest line in the group takes to slide. Together those are everything a line needs to work
/// out where it should be without asking anyone.
struct MarqueeClock: Equatable {

    /// When the current loop started. Reset when the text changes, so a new track is held from
    /// the beginning of its title rather than picked up mid-slide.
    var epoch: Date
    /// The longest slide in the group. Shorter lines finish early and wait it out.
    var scrollDuration: Double

    /// What a `MarqueeText` gets when nobody wrapped it in a `MarqueeGroup`. It starts whenever
    /// this is first read and never resets: a lone line still scrolls, it just has nothing to
    /// keep step with.
    static let unsynchronized = MarqueeClock(epoch: Date(), scrollDuration: 0)
}

/// Keeps the marquees inside it on one beat — they set off together and start again together,
/// however differently long their text is. See `MarqueeCycle` for what "together" costs (the
/// short line spends the difference parked) and why it beats letting each line free-run.
///
/// The lines report what they need through a preference and read the answer back through the
/// environment. That round trip is why this is a container and not a parameter: a marquee's
/// slide time depends on how wide its text turns out to be, which nobody knows until layout has
/// happened, so the group cannot be told up front and has to be told from below.
struct MarqueeGroup<Content: View>: View {

    @ViewBuilder var content: Content

    @State private var clock = MarqueeClock(epoch: Date(), scrollDuration: 0)
    /// What the group was showing last time it looked. Only a change of *text* restarts the
    /// loop; a width change (a rotation, a resized column) leaves the beat alone, because
    /// restarting mid-slide is more jarring than the slightly different loop length.
    @State private var texts: [String] = []

    var body: some View {
        content
            .environment(\.marqueeClock, clock)
            .onPreferenceChange(MarqueeMeasurementKey.self) { measurement in
                if measurement.texts != texts {
                    texts = measurement.texts
                    clock = MarqueeClock(epoch: Date(), scrollDuration: measurement.scrollDuration)
                } else if measurement.scrollDuration != clock.scrollDuration {
                    clock.scrollDuration = measurement.scrollDuration
                }
            }
    }
}

/// What one line contributes to its group: what it says, and how long it needs to say it.
struct MarqueeMeasurement: Equatable {
    var texts: [String] = []
    var scrollDuration: Double = 0
}

/// Collects every line in the group into one measurement. The durations reduce by `max` — the
/// group runs at the pace of its slowest line — and the texts accumulate in view order, so the
/// group can tell "the track changed" from "the same track, measured again".
struct MarqueeMeasurementKey: PreferenceKey {
    static var defaultValue = MarqueeMeasurement()

    static func reduce(value: inout MarqueeMeasurement, nextValue: () -> MarqueeMeasurement) {
        let next = nextValue()
        value.texts += next.texts
        value.scrollDuration = max(value.scrollDuration, next.scrollDuration)
    }
}

extension EnvironmentValues {
    @Entry var marqueeClock: MarqueeClock = .unsynchronized
}
