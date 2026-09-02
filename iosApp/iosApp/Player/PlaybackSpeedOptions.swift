import Foundation

/// The speeds the expanded player's "Playback speed" submenu offers, and how each is written.
///
/// The server takes any value from 0.5 to 3.0, but a menu wants a short list, so these are the
/// same nine presets upstream's slider dialog pinned as chips. A queue can still sit at a speed
/// off that grid — set from another client's slider — and a `Picker` whose selection matches no
/// row draws no checkmark at all, so `rows(current:)` splices the current value in where it
/// sorts. Pure so `PlaybackSpeedOptionsTests` can pin it without a device.
enum PlaybackSpeedOptions {
    static let presets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// `speed` rounded to the hundredth the server itself works in, so a value like 1.2500001
    /// matches its preset instead of appearing as a tenth row beside it.
    static func normalized(_ speed: Double) -> Double {
        (speed * 100).rounded() / 100
    }

    /// The presets, plus `current` in sorted position when it is not one of them.
    static func rows(current: Double) -> [Double] {
        let value = normalized(current)
        if presets.contains(value) { return presets }
        return (presets + [value]).sorted()
    }

    /// "1×", "1.25×" — trailing zeros dropped, decimal separator per `locale`.
    static func label(for speed: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let value = normalized(speed)
        let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(number)×"
    }
}
