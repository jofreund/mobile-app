import SwiftUI
import MusicAssistantKit

/// Local player (Sendspin) configuration: enable/disable, player name, optional
/// custom connection, encryption requirement. All fields lock while the local player
/// is running (config is connect-time; changes take effect on the next connect),
/// matching upstream's Compose section.
///
/// The enable toggle only writes the setting — `MainDataSource` watches
/// `sendspinEnabled` and starts/stops the player itself, so flipping it here acts
/// immediately with no reconnect.
struct LocalPlayerSection: View {

    // Settings are single-writer (this view), so they're read once and written
    // through the KmpHelper setters; only the live status needs a subscription.
    @State private var enabled = KmpHelper.shared.sendspinEnabled.value?.boolValue ?? false
    @State private var deviceName = KmpHelper.shared.sendspinDeviceName.value ?? ""
    @State private var requireEncryption =
        KmpHelper.shared.sendspinRequireEncryption.value?.boolValue ?? false
    @State private var useCustomConnection =
        KmpHelper.shared.sendspinUseCustomConnection.value?.boolValue ?? false
    @State private var host = KmpHelper.shared.sendspinHost.value ?? ""
    @State private var port = KmpHelper.shared.sendspinPort.value.map { "\($0.intValue)" } ?? "8095"
    @State private var path = KmpHelper.shared.sendspinPath.value ?? "/sendspin"
    @State private var useTls = KmpHelper.shared.sendspinUseTls.value?.boolValue ?? false

    @State private var running = KmpHelper.shared.sendspinRunning.value?.boolValue ?? false
    @State private var status = KmpHelper.shared.sendspinStatus.value ?? "stopped"
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

            Toggle(
                String(localized: "settings_sendspin_require_encryption"),
                isOn: Binding(
                    get: { requireEncryption },
                    set: { newValue in
                        requireEncryption = newValue
                        KmpHelper.shared.setSendspinRequireEncryption(enabled: newValue)
                    }
                )
            )
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
                status = value ?? "stopped"
            }
        }
    }
}
