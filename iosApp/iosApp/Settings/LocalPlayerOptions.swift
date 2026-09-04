import Foundation

/// The rows the Local Player section's codec and buffer-size pickers show, and how each is
/// labelled. The values themselves come from Kotlin — `Codecs.list` and `SendspinConfig`'s
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

    /// One row of the buffer-size picker. The setting stays megabytes on the wire (it is the
    /// advertised `buffer_capacity`); the row just names a point on that scale in words.
    struct BufferSizeRow: Equatable, Identifiable {
        let mb: Int
        /// Catalog key of the tier name ("settings_buffer_tier_medium"), nil for a stored size
        /// that matches no tier — that row is titled by its size instead.
        let tierKey: String?
        /// Catalog key of the one-line explanation shown under the name.
        let descriptionKey: String
        var id: Int { mb }
    }

    /// The four sizes the picker offers, out of the ten the kernel accepts. Nobody tunes
    /// between 20 and 25 MB; the real choice is "leave it", "more headroom for a flaky
    /// network", or "this phone is tight on memory", so that is what the rows say.
    static let tiers: [BufferSizeRow] = [
        BufferSizeRow(mb: 5, tierKey: "settings_buffer_tier_small", descriptionKey: "settings_buffer_tier_small_hint"),
        BufferSizeRow(mb: 15, tierKey: "settings_buffer_tier_medium", descriptionKey: "settings_buffer_tier_medium_hint"),
        BufferSizeRow(mb: 30, tierKey: "settings_buffer_tier_large", descriptionKey: "settings_buffer_tier_large_hint"),
        BufferSizeRow(mb: 50, tierKey: "settings_buffer_tier_maximum", descriptionKey: "settings_buffer_tier_maximum_hint"),
    ]

    /// The tiers the kernel actually accepts (`kernelOptions` is `SendspinConfig`'s grid, so a
    /// tier outside a future limit change silently drops out rather than being sent), plus
    /// `current` as an untitled row when it matches no tier — a size stored by another build,
    /// or set on the full grid before this picker existed — so the picker never shows nothing.
    static func bufferSizeRows(kernelOptions: [Int], current: Int) -> [BufferSizeRow] {
        var rows = tiers.filter { kernelOptions.contains($0.mb) }
        if !rows.contains(where: { $0.mb == current }) {
            rows.append(BufferSizeRow(mb: current, tierKey: nil, descriptionKey: "settings_buffer_tier_custom_hint"))
        }
        return rows.sorted { $0.mb < $1.mb }
    }

    /// "15 MB", digits and grouping per `locale`: the secondary line of every tier row and the
    /// title of an untitled one. The unit is the decimal megabyte the Sendspin spec and
    /// `SendspinConfig.BYTES_PER_MB` use, so what the row says is what the server is told.
    static func bufferSizeLabel(mb: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: mb)) ?? String(mb)
        return "\(number) MB"
    }
}
