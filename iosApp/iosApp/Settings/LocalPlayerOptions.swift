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

    /// Same rule for buffer sizes, spliced in where the size sorts so the menu stays ordered.
    static func bufferSizeRows(_ options: [Int], current: Int) -> [Int] {
        if options.contains(current) { return options }
        return (options + [current]).sorted()
    }

    /// "15 MB", digits and grouping per `locale`. The unit is the decimal megabyte the Sendspin
    /// spec and `SendspinConfig.BYTES_PER_MB` use, so what the row says is what the server is
    /// told.
    static func bufferSizeLabel(mb: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: mb)) ?? String(mb)
        return "\(number) MB"
    }
}
