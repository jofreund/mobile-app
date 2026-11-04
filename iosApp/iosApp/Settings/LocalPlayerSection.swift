import SwiftUI
import MusicAssistantKit

/// Local player (Sendspin) configuration: enable/disable, player name, codec preference,
/// 24-bit audio, buffer length, optional custom connection. All fields lock while the local player is
/// running (each is part of the player's hello, so a change would reconnect it mid-stream).
/// There is no encryption switch: the `:sendspin-kmp` player is always encrypted.
///
/// The enable toggle only writes the setting — the player follows `LocalPlayerAdapter`'s
/// config, so flipping it here starts or stops it right away.
struct LocalPlayerSection: View {

    // Settings are single-writer (this view), so they're read once and written
    // through the KmpHelper setters; only the live status needs a subscription.
    // NativeStateFlow<T>'s generic T loses Swift's automatic NSString bridging
    // (see ConnectionSetupStore.swift), hence the explicit `as String?` casts.
    @State private var enabled = KmpHelper.shared.sendspinEnabled.value?.boolValue ?? false
    @State private var deviceName = (KmpHelper.shared.sendspinDeviceName.value as? String) ?? ""
    @State private var codec = (KmpHelper.shared.sendspinCodecPreference.value as? String) ?? ""
    @State private var hiRes = KmpHelper.shared.sendspinHiRes.value?.boolValue ?? false
    @State private var bufferSeconds = KmpHelper.shared.sendspinBufferSeconds.value?.intValue
        ?? Int(KmpHelper.shared.sendspinBufferSecondsDefault)
    @State private var useCustomConnection =
        KmpHelper.shared.sendspinUseCustomConnection.value?.boolValue ?? false
    @State private var host = (KmpHelper.shared.sendspinHost.value as? String) ?? ""
    @State private var port = KmpHelper.shared.sendspinPort.value.map { "\($0.intValue)" } ?? "8095"
    @State private var path = (KmpHelper.shared.sendspinPath.value as? String) ?? "/sendspin"
    @State private var useTls = KmpHelper.shared.sendspinUseTls.value?.boolValue ?? false

    // What the two pickers may offer is fixed by the kernel (the codec list, `SettingsRepository`'s
    // buffer limits), so it is read once; only the labels are Swift's (`LocalPlayerOptions`).
    private let codecOptions: [String] = KmpHelper.shared.sendspinCodecOptions
    private let bufferOptions: [Int] = KmpHelper.shared.sendspinBufferSecondsOptions.map { $0.intValue }
    private let defaultBufferSeconds = Int(KmpHelper.shared.sendspinBufferSecondsDefault)

    @State private var running = KmpHelper.shared.sendspinRunning.value?.boolValue ?? false
    @State private var status = (KmpHelper.shared.sendspinStatus.value as? String) ?? "stopped"
    @State private var runningSub: Cancellable?
    @State private var statusSub: Cancellable?

    var body: some View {
        Section(String(localized: "settings_local_player_disabled")) {
            Toggle(
                String(localized: "settings_enable_local_player"),
                isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        enabled = newValue
                        KmpHelper.shared.setSendspinEnabled(enabled: newValue)
                    }
                )
            )

            if enabled {
                LabeledContent(String(localized: "settings_local_player_status")) {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }

            TextField(
                String(localized: "settings_player_name"),
                text: $deviceName
            )
            .disabled(running)
            .onChange(of: deviceName) { _, newValue in
                KmpHelper.shared.setSendspinDeviceName(name: newValue)
            }

            // Codec and buffer length are advertised in the client hello, so like the name they
            // lock while running and apply on the next connect. Inline rows for the codec: three
            // options whose labels are the explanation, and a menu would truncate them.
            Picker(String(localized: "settings_codec_preference"), selection: codecBinding) {
                ForEach(LocalPlayerOptions.codecRows(codecOptions, current: codec), id: \.self) { name in
                    Text(codecLabel(for: name)).tag(name)
                }
            }
            .pickerStyle(.inline)
            .disabled(running)

            // 24-bit applies to FLAC and PCM only (Opus is always 16-bit), so with Opus the toggle
            // shows off and says why; the stored choice comes back with a lossless codec.
            Toggle(isOn: hiResBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings_hi_res_audio"))
                    Text(String(localized: String.LocalizationValue(
                        hiResAvailable ? "settings_hi_res_audio_hint" : "settings_hi_res_audio_lossless_only"
                    )))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(running || !hiResAvailable)

            // Buffer length as named tiers over the kernel's seconds grid (`LocalPlayerOptions.tiers`):
            // the choice is about headroom versus memory, not a number, so the number is the
            // secondary line. Inline too, so the explanations are readable without opening a menu.
            Picker(selection: bufferBinding) {
                ForEach(LocalPlayerOptions.bufferSizeRows(kernelOptions: bufferOptions, current: bufferSeconds)) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bufferTitle(for: row))
                        Text(bufferDetail(for: row))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .tag(row.seconds)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings_buffer_size"))
                    Text(String(localized: "settings_buffer_size_hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.inline)
            .disabled(running)

            Toggle(
                String(localized: "settings_custom_sendspin"),
                isOn: Binding(
                    get: { useCustomConnection },
                    set: { newValue in
                        useCustomConnection = newValue
                        KmpHelper.shared.setSendspinUseCustomConnection(enabled: newValue)
                    }
                )
            )
            .disabled(running)

            if useCustomConnection {
                TextField(String(localized: "settings_host"), text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .disabled(running)
                    .onChange(of: host) { _, newValue in
                        KmpHelper.shared.setSendspinHost(host: newValue)
                    }

                TextField(String(localized: "settings_port_default"), text: $port)
                    .keyboardType(.numberPad)
                    .disabled(running)
                    .onChange(of: port) { _, newValue in
                        // Persist only parseable values; a half-typed field keeps the last
                        // stored port (config is connect-time anyway).
                        if let parsed = Int32(newValue), parsed > 0 {
                            KmpHelper.shared.setSendspinPort(port: parsed)
                        }
                    }

                TextField(String(localized: "settings_path"), text: $path)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(running)
                    .onChange(of: path) { _, newValue in
                        KmpHelper.shared.setSendspinPath(path: newValue)
                    }

                Toggle(
                    String(localized: "settings_use_tls"),
                    isOn: Binding(
                        get: { useTls },
                        set: { newValue in
                            useTls = newValue
                            KmpHelper.shared.setSendspinUseTls(enabled: newValue)
                        }
                    )
                )
                .disabled(running)
            }
        }
        .task {
            guard runningSub == nil else { return }
            runningSub = KmpHelper.shared.sendspinRunning.subscribe { value in
                running = value?.boolValue ?? false
            }
            statusSub = KmpHelper.shared.sendspinStatus.subscribe { value in
                status = (value as? String) ?? "stopped"
            }
        }
    }

    // MARK: - Codec and buffer size

    private var codecBinding: Binding<String> {
        Binding(
            get: { codec },
            set: { newValue in
                codec = newValue
                KmpHelper.shared.setSendspinCodecPreference(codecName: newValue)
            }
        )
    }

    private var hiResAvailable: Bool {
        KmpHelper.shared.sendspinHiResAvailable(codecName: codec)
    }

    private var hiResBinding: Binding<Bool> {
        Binding(
            get: { hiRes && hiResAvailable },
            set: { newValue in
                hiRes = newValue
                KmpHelper.shared.setSendspinHiRes(enabled: newValue)
            }
        )
    }

    private var bufferBinding: Binding<Int> {
        Binding(
            get: { bufferSeconds },
            set: { newValue in
                bufferSeconds = newValue
                KmpHelper.shared.setSendspinBufferSeconds(seconds: Int32(newValue))
            }
        )
    }

    /// "Opus (compressed, lowest bandwidth)" — the catalog's text for the codec, or the raw
    /// name for one the catalog does not know, so the row is never blank.
    private func codecLabel(for name: String) -> String {
        guard let key = LocalPlayerOptions.codecLabelKey(for: name) else { return name }
        return String(localized: String.LocalizationValue(key))
    }

    /// "Medium (default)" for a tier — the marker follows the kernel's default, not a Swift
    /// constant — or "15 s" for a stored length that matches no tier.
    private func bufferTitle(for row: LocalPlayerOptions.BufferSizeRow) -> String {
        guard let key = row.tierKey else { return LocalPlayerOptions.bufferSizeLabel(seconds: row.seconds) }
        let name = String(localized: String.LocalizationValue(key))
        guard row.seconds == defaultBufferSeconds else { return name }
        return String(format: String(localized: "settings_buffer_size_default"), name)
    }

    /// "Balanced for most Wi-Fi · 10 s": the explanation, then the length buffered.
    /// An untitled row already has its length as the title, so it shows the explanation alone.
    private func bufferDetail(for row: LocalPlayerOptions.BufferSizeRow) -> String {
        let description = String(localized: String.LocalizationValue(row.descriptionKey))
        guard row.tierKey != nil else { return description }
        return "\(description) · \(LocalPlayerOptions.bufferSizeLabel(seconds: row.seconds))"
    }
}
