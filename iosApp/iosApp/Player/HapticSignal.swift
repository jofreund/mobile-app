import SwiftUI

/// One haptic attachment point per view, fired imperatively from control actions.
///
/// `.sensoryFeedback` is declarative and wants a trigger value that changes, which fits state
/// observation better than it fits "the user just tapped this". Driving it from a counter gives
/// the declarative API an imperative entry point, so a button action reads
/// `haptic.fire(.impact(weight: .light))` next to the store call it accompanies.
///
/// **Fired on the tap, not on the resulting state — deliberately.** Triggering on the state that
/// comes back would be tempting (it would confirm the server actually did the thing) but this is
/// a remote control for a shared player: someone pausing from the web UI would buzz a phone
/// sitting on a table. It would also double-fire, because the mini player stays mounted
/// underneath the expanded player and both observe the same store. Tap-time feedback belongs to
/// the control that was touched, which is both Apple's guidance and the only version that can't
/// fire spuriously.
struct HapticSignal: Equatable {

    private var counter = 0
    fileprivate private(set) var feedback: SensoryFeedback = .impact(weight: .light)

    /// Only the counter participates in equality — the feedback is payload, not identity, and
    /// firing the same kind twice in a row must still register as a change.
    static func == (lhs: HapticSignal, rhs: HapticSignal) -> Bool { lhs.counter == rhs.counter }

    mutating func fire(_ feedback: SensoryFeedback) {
        self.feedback = feedback
        counter += 1
    }
}

extension View {
    /// Attach once per view; every `fire` on [signal] plays through here.
    func haptics(_ signal: HapticSignal) -> some View {
        sensoryFeedback(trigger: signal) { _, latest in latest.feedback }
    }
}
