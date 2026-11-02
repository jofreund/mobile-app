import Foundation

/// The rows the Local Player section's codec and buffer-size pickers show, and how each is
/// labelled. The values themselves come from Kotlin — the codec list and `SettingsRepository`'s
/// buffer limits, read through `KmpHelper` — so the two platforms can never disagree on what
/// the setting accepts; this file only turns them into text. Pure so
/// `LocalPlayerOptionsTests` can pin the labels without a device.
enum LocalPlayerOptions {

    /// The string-catalog key for a codec name as Kotlin reports it ("OPUS" → "codec_opus"),
    /// or nil for a codec this build has no label for. The caller then shows the raw name, so
    /// a codec added upstream still gets a row rather than a blank one.
    static func codecLabelKey(for codecName: String) -> String? {
        switch codecName.uppercased() {
        case "OPUS": return "codec_opus"
        case "FLAC": return "codec_flac"
        case "PCM": return "codec_pcm"
        default: return nil
        }
    }

    /// `options` with `current` appended when it is not one of them: a `Picker` whose selection
    /// matches no row draws no checkmark at all, so a value stored by another build (or a codec
    /// this platform no longer lists) still shows as what is set rather than as nothing.
    static func codecRows(_ options: [String], current: String) -> [String] {
        if current.isEmpty || options.contains(current) { return options }
        return options + [current]
    }

    /// One row of the buffer-size picker. The setting is seconds of audio; the player sizes the
    /// advertised `buffer_capacity` from it. The row names a point on that scale in words.
    struct BufferSizeRow: Equatable, Identifiable {
        let seconds: Int
        /// Catalog key of the tier name ("settings_buffer_tier_medium"), nil for a stored length
        /// that matches no tier — that row is titled by its length instead.
        let tierKey: String?
        /// Catalog key of the one-line explanation shown under the name.
        let descriptionKey: String
        var id: Int { seconds }
    }

    /// The four lengths the picker offers, out of the six the kernel accepts. The real choice is
    /// "leave it", "more headroom for a flaky network", or "this phone is tight on memory", so
    /// that is what the rows say. The old megabyte tiers map onto these one to one
    /// (`SettingsRepository.bufferSecondsForMegabytes`), so a stored choice keeps its row.
    static let tiers: [BufferSizeRow] = [
        BufferSizeRow(seconds: 5, tierKey: "settings_buffer_tier_small", descriptionKey: "settings_buffer_tier_small_hint"),
        BufferSizeRow(seconds: 10, tierKey: "settings_buffer_tier_medium", descriptionKey: "settings_buffer_tier_medium_hint"),
        BufferSizeRow(seconds: 20, tierKey: "settings_buffer_tier_large", descriptionKey: "settings_buffer_tier_large_hint"),
        BufferSizeRow(seconds: 30, tierKey: "settings_buffer_tier_maximum", descriptionKey: "settings_buffer_tier_maximum_hint"),
    ]

    /// The tiers the kernel actually accepts (`kernelOptions` is `SettingsRepository`'s grid, so a
    /// tier outside a future limit change silently drops out rather than being stored), plus
    /// `current` as an untitled row when it matches no tier — a length stored by another build —
    /// so the picker never shows nothing.
    static func bufferSizeRows(kernelOptions: [Int], current: Int) -> [BufferSizeRow] {
        var rows = tiers.filter { kernelOptions.contains($0.seconds) }
        if !rows.contains(where: { $0.seconds == current }) {
            rows.append(BufferSizeRow(seconds: current, tierKey: nil, descriptionKey: "settings_buffer_tier_custom_hint"))
        }
        return rows.sorted { $0.seconds < $1.seconds }
    }

    /// "10 s", digits per `locale`: the secondary line of every tier row and the title of an
    /// untitled one. The SI symbol needs no translation.
    static func bufferSizeLabel(seconds: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: seconds)) ?? String(seconds)
        return "\(number) s"
    }
}
