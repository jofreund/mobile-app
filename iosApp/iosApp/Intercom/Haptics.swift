import Foundation
#if canImport(CoreHaptics)
import CoreHaptics
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Push-to-talk lives on feedback you can feel without looking at the screen.
@MainActor
enum Haptics {
    #if canImport(UIKit)
    // One long-lived generator per feel, rather than a fresh one per tap.
    //
    // `prepare()` warms the Taptic Engine *for the generator it is called on*,
    // and a generator that is thrown away takes that warmth with it — so
    // preparing one instance and firing another is the same cold engine as
    // preparing nothing at all, and a cold engine drops or delays the tap
    // rather than playing it late. Kept here, these are the instances that
    // actually fire, so priming them means something.
    private static let start = UIImpactFeedbackGenerator(style: .medium)
    private static let stop = UIImpactFeedbackGenerator(style: .light)
    private static let cancelled = UIImpactFeedbackGenerator(style: .heavy)
    private static let outcome = UINotificationFeedbackGenerator()
    #endif

    #if canImport(CoreHaptics)
    /// The start tap does not go through `UIImpactFeedbackGenerator` — see
    /// ``StartTapEngine``.
    private static let startTap = StartTapEngine()
    #endif

    private static var keepWarmTask: Task<Void, Never>?

    /// How often the engine is re-primed while the grid is up. `prepare()`
    /// holds for a second or two, so this has to be comfortably under that.
    private static let keepWarmInterval: Duration = .milliseconds(1200)

    /// Spins the Taptic Engine up before it's needed. Call this whenever the
    /// app becomes usable, well before the first press.
    static func prepare() {
        #if canImport(CoreHaptics)
        startTap.start()
        #endif
        #if canImport(UIKit)
        start.prepare()
        #endif
    }

    /// Keeps the engine primed for as long as the grid is on screen.
    ///
    /// A single `prepare()` when the view appears is not enough. Push-to-talk
    /// gets exactly one chance at the start tap, and it is asked for it a
    /// third of a second after touch-down — once the press has outlasted a
    /// tap and the pop-over has finished growing, with the mic opening right
    /// behind it (see `IntercomViewModel.pressBegan(on:)`) — in a turn that
    /// cannot afford to warm the engine first. `prepare()` keeps it warm for
    /// only a second or two, so any press that follows a pause — the user
    /// reading the grid, deciding which speaker — would otherwise ask a cold
    /// engine for a tap, and a cold engine drops it rather than playing it
    /// late. That is the press that doesn't buzz.
    ///
    /// What this costs is the Taptic Engine idling while the intercom tab is
    /// in the foreground, which is the trade this app should take: the tap is
    /// how you know the microphone is yours without looking at the screen.
    /// It stops with the tab and with the app.
    static func startKeepingWarm() {
        #if canImport(CoreHaptics)
        // The engine the start tap actually plays on. It is not on a timer:
        // once running it stays running for as long as the grid is up.
        startTap.start()
        #endif
        #if canImport(UIKit)
        guard keepWarmTask == nil else { return }
        keepWarmTask = Task {
            while !Task.isCancelled {
                start.prepare()
                try? await Task.sleep(for: keepWarmInterval)
            }
        }
        #endif
    }

    static func stopKeepingWarm() {
        #if canImport(CoreHaptics)
        startTap.stop()
        #endif
        #if canImport(UIKit)
        keepWarmTask?.cancel()
        keepWarmTask = nil
        #endif
    }

    /// The tap that marks the start of a recording — and nothing else.
    ///
    /// It fires as the pop-over lands, with the mic opening right behind it,
    /// which is the busiest main-thread moment of the whole press. Anything
    /// else asked of the haptic server here is another synchronous hop in the
    /// frame the card is still settling in; the priming that used to sit
    /// behind this call is now ``prepareForRelease()``, run once the recorder
    /// is genuinely capturing and the rush is over.
    ///
    /// Played on the Core Haptics engine of ``StartTapEngine``, with the
    /// `UIKit` generator kept as the fallback for the one case that engine
    /// cannot serve: a device or a moment where it will not start at all.
    static func recordingStarted() {
        #if canImport(CoreHaptics)
        if startTap.play() { return }
        #endif
        #if canImport(UIKit)
        start.impactOccurred()
        #endif
    }

    /// Primes the two taps that can end a press. Called once the recording is
    /// actually running: either of them is at least a held moment away, and
    /// `prepare()` keeps a generator warm for a second or two.
    static func prepareForRelease() {
        #if canImport(UIKit)
        stop.prepare()
        cancelled.prepare()
        #endif
    }

    static func recordingStopped() {
        #if canImport(UIKit)
        stop.impactOccurred()
        // The send outcome follows within a second or two; the next press
        // could too.
        outcome.prepare()
        start.prepare()
        #endif
    }

    /// A stop that discards instead of sending — deliberately a stronger,
    /// two-beat feel so the thumb can tell "this went nowhere" apart from
    /// both the single light tap of a normal stop and the success/warning/
    /// error notification patterns used for send outcomes.
    static func recordingCancelled() {
        #if canImport(UIKit)
        cancelled.impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            cancelled.impactOccurred()
            // The card goes straight back to idle after a slide-off, so the
            // next press can come immediately.
            start.prepare()
        }
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        outcome.notificationOccurred(.success)
        start.prepare()
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        outcome.notificationOccurred(.warning)
        start.prepare()
        #endif
    }

    static func failure() {
        #if canImport(UIKit)
        outcome.notificationOccurred(.error)
        start.prepare()
        #endif
    }
}

#if canImport(CoreHaptics)
/// The start tap, on an engine of its own.
///
/// `UIImpactFeedbackGenerator` plays through the system feedback path, and
/// that path is silenced while the app holds an **active** `.playAndRecord`
/// audio session — iOS keeps the motor's buzz out of recordings. The tap is
/// deliberately fired before `recorder.start()` for exactly that reason, but
/// the press is not the only thing that activates the session: the warm-up
/// recorder's `prepareToRecord()` does too, implicitly, and the session then
/// stays active until the next stop deactivates it. So whether the start tap
/// was audible came down to what the previous press had left behind — which
/// is the "sometimes it buzzes" the grid was showing.
///
/// A `CHHapticEngine` with ``CHHapticEngine/playsHapticsOnly`` set carries no
/// audio session of its own and is not routed through the system feedback
/// path, so the recording session has nothing to mute. The engine is started
/// once with the grid rather than primed per press, which also removes the
/// other half of the old problem: nothing here can go cold between presses.
@MainActor
final class StartTapEngine {
    private static let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// Intensity and sharpness of a single transient event, chosen to sit
    /// where the old `.medium` impact sat.
    private static let intensity: Float = 0.8
    private static let sharpness: Float = 0.5

    private var engine: CHHapticEngine?
    /// Built once with the engine: starting a player that already exists is
    /// the shortest path there is from the call to the motor.
    private var player: CHHapticPatternPlayer?
    /// True between ``start()`` and ``stop()``. The engine's own handlers use
    /// it to tell a drop-out — which should come back — from the shutdown the
    /// grid asked for, which should not.
    private var isWanted = false

    func start() {
        guard Self.isSupported else { return }
        isWanted = true
        guard engine == nil else { return }

        do {
            let engine = try CHHapticEngine()
            // No audio in this pattern, and an engine without an audio
            // session is an engine the recorder cannot silence.
            engine.playsHapticsOnly = true
            // The grid decides when this engine goes away; an idle timeout
            // would put us back to warming something up per press.
            engine.isAutoShutdownEnabled = false
            // A reset (haptic server restart) or a stop we did not ask for
            // (an audio interruption, a scene leaving the foreground) leaves
            // a dead engine behind: build a fresh one.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.restart() }
            }
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.restart() }
            }
            self.player = try engine.makePlayer(with: Self.pattern())
            self.engine = engine
            engine.start { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.discard() }
            }
        } catch {
            discard()
        }
    }

    func stop() {
        isWanted = false
        engine?.stop()
        discard()
    }

    /// Plays the tap. Returns `false` if it could not be played, so the caller
    /// can fall back to the system generator.
    @discardableResult
    func play() -> Bool {
        guard let player else { return false }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            // The engine died between the last press and this one. Rebuild it
            // for the next press and let this one go through UIKit.
            restart()
            return false
        }
    }

    private func restart() {
        guard isWanted else { return }
        discard()
        start()
    }

    private func discard() {
        engine = nil
        player = nil
    }

    private static func pattern() throws -> CHHapticPattern {
        let tap = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [tap], parameters: [])
    }
}
#endif
