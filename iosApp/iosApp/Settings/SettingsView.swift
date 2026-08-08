import SwiftUI
import ComposeApp

/// Settings — Phase E4, part 1. `SettingsScreen.kt` (1,309 LOC) does double duty as both
/// first-run/reconnect connection setup (host/port/TLS, WebRTC + QR scan, connection history)
/// *and* the authenticated settings screen (server info, login, Sendspin/local-player config,
/// Car actions, DSP, theme, logs). The connection-setup and authentication pieces sit on top of
/// real protocol/session logic (`AuthenticationManager`'s server-ID-mismatch detection and
/// per-server token lifecycle, `SilentReauth`'s bounded-retry-vs-surface-immediately asymmetry)
/// that must not be hand-reimplemented — getting it subtly wrong risks actually locking a user
/// out, a materially worse failure mode than anything native so far. So this screen only goes
/// native for the sections reachable once already connected *and* authenticated (server info,
/// account/logout, theme, Sendspin, logs); everything else falls back to hosting the existing,
/// completely unmodified Compose `SettingsScreen` via `ComposeHostView` — a user mid-connection-
/// setup or logging in sees exactly what they see today. Car actions/DSP settings are deferred
/// too (lower usage — CarPlay-specific — same low-risk pass-through shape as Sendspin, just not
/// done yet) and stay reachable only through the Compose fallback for now.
///
/// `KmpHelper.sessionState` exposes the real Kotlin `SessionState` sealed class directly (same
/// pattern `AppTabView.swift` already uses for `DeepLinkDestination`) so this view can branch on
/// the exact same states Compose does, rather than a flattened re-derivation that could drift.
struct SettingsView: View {

    @State private var sessionState: SessionState?
    @State private var subscription: Cancellable?

    var body: some View {
        NavigationStack {
            Group {
                if let connected = sessionState as? SessionState.Connected,
                   let authenticated = connected.dataConnectionState as? DataConnectionStateAuthenticated {
                    nativeContent(connected: connected, authenticated: authenticated)
                } else {
                    ComposeHostView(makeController: { ComposeScreenHostsKt.SettingsAppController() })
                        .ignoresSafeArea()
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .navigationTitle(String(localized: "nav_settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        KmpHelper.shared.requestHome()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .task {
            guard subscription == nil else { return }
            subscription = KmpHelper.shared.sessionState.subscribe { [self] state in
                sessionState = state
            }
        }
    }

    @ViewBuilder
    private func nativeContent(connected: SessionState.Connected, authenticated: DataConnectionStateAuthenticated) -> some View {
        Form {
            serverInfoSection(connected: connected)
            if let user = connected.user {
                accountSection(user: user)
            }
            themeSection
            // SendspinSection() intentionally not shown — local player is a reduced-scope
            // feature for now (product decision, not a technical gap). Left defined below,
            // not deleted, and KmpHelper's Sendspin bridge methods stay as-is: re-add this
            // line to bring it back.
            miscSection
        }
    }

    // MARK: - Server info

    private func serverInfoSection(connected: SessionState.Connected) -> some View {
        Section(String(localized: "settings_server")) {
            if let direct = connected as? SessionState.ConnectedDirect {
                Text(
                    String(
                        format: String(localized: "settings_connected_to"),
                        direct.connectionInfo.host,
                        direct.connectionInfo.port
                    )
                )
            } else {
                Text(String(localized: "settings_connected_webrtc"))
            }
            if let serverInfo = connected.serverInfo {
                Text(
                    String(
                        format: String(localized: "settings_version_info"),
                        serverInfo.serverVersion ?? "",
                        serverInfo.schemaVersion?.stringValue ?? ""
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                KmpHelper.shared.serviceClient.disconnectByUser()
            } label: {
                Text(String(localized: "settings_disconnect"))
            }
        }
    }

    // MARK: - Account

    private func accountSection(user: User) -> some View {
        Section(String(localized: "auth_title")) {
            Text(String(format: String(localized: "auth_logged_in_as"), user.description_))
            Button(String(localized: "auth_logout")) {
                KmpHelper.shared.serviceClient.logout()
            }
        }
    }

    // MARK: - Theme

    // Compose's own ThemeChooser is icon-only (sun / circle-half / moon), no text labels exist
    // for the three settings — matched here rather than inventing new localized strings.
    private var themeSection: some View {
        Section {
            Picker("", selection: themeBinding) {
                Image(systemName: "sun.max").tag(ThemeSetting.light)
                Image(systemName: "circle.lefthalf.filled").tag(ThemeSetting.followsystem)
                Image(systemName: "moon").tag(ThemeSetting.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var themeBinding: Binding<ThemeSetting> {
        Binding(
            get: { KmpHelper.shared.theme() },
            set: { KmpHelper.shared.switchTheme(theme: $0) }
        )
    }

    // MARK: - Misc / logs

    private var miscSection: some View {
        MiscLogsSection()
    }
}

/// Isolated into its own view so `@State` for the share-in-flight/crash-log-present flags
/// doesn't need to live on `SettingsView` itself.
private struct MiscLogsSection: View {

    @State private var hasCrashLog = KmpHelper.shared.hasCrashLog()
    @State private var isPreparingShare = false

    var body: some View {
        Section(String(localized: "settings_misc")) {
            Button {
                shareLogs()
            } label: {
                HStack {
                    Text(String(localized: "settings_share_logs"))
                    if isPreparingShare {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isPreparingShare)

            if hasCrashLog {
                Button(String(localized: "settings_share_crash_logs")) {
                    shareCrashLog()
                }
                .disabled(isPreparingShare)

                Button(role: .destructive) {
                    KmpHelper.shared.deleteCrashLog()
                    hasCrashLog = false
                } label: {
                    Text(String(localized: "cd_delete_crash_logs"))
                }
                .disabled(isPreparingShare)
            }
        }
    }

    private func shareLogs() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        KmpHelper.shared.shareLogs(chooserTitle: String(localized: "settings_share_logs")) {
            isPreparingShare = false
        }
    }

    private func shareCrashLog() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        KmpHelper.shared.shareCrashLog(chooserTitle: String(localized: "settings_share_crash_logs")) {
            isPreparingShare = false
        }
    }
}

/// The local-player (Sendspin) config section — device name, codec, buffer size, optional
/// custom connection, enable/disable. All fields lock while the local player is running
/// (config is connect-time; changes take effect on the next connect), matching Compose exactly.
private struct SendspinSection: View {

    @State private var enabled = KmpHelper.shared.sendspinEnabled()
    @State private var deviceName = KmpHelper.shared.sendspinDeviceName()
    @State private var codec = KmpHelper.shared.sendspinCodecPreference()
    @State private var bufferMb = Int(KmpHelper.shared.sendspinBufferCapacityMb())
    @State private var useCustomConnection = KmpHelper.shared.sendspinUseCustomConnection()
    @State private var host = KmpHelper.shared.sendspinHost()
    @State private var port = String(KmpHelper.shared.sendspinPort())
    @State private var path = KmpHelper.shared.sendspinPath()
    @State private var useTls = KmpHelper.shared.sendspinUseTls()

    // Mirrors SendspinConfig.BUFFER_MB_MIN/MAX/STEP (Kotlin companion constants, hardcoded here
    // rather than bridged — a stable trio of numbers not worth a bridge method for).
    private let bufferRange: ClosedRange<Double> = 5...50
    private let bufferStep: Double = 5

    private let codecOptions = KmpHelper.shared.sendspinCodecOptions()

    var body: some View {
        Section(String(localized: enabled ? "settings_local_player_enabled" : "settings_local_player_disabled")) {
            TextField(String(localized: "settings_player_name"), text: $deviceName)
                .disabled(enabled)
                .onChange(of: deviceName) { _, newValue in KmpHelper.shared.setSendspinDeviceName(name: newValue) }

            Picker(String(localized: "settings_codec_preference"), selection: $codec) {
                ForEach(codecOptions, id: \.self) { option in
                    Text(option.uiTitle()).tag(option)
                }
            }
            .disabled(enabled)
            .onChange(of: codec) { _, newValue in KmpHelper.shared.setSendspinCodecPreference(codec: newValue) }

            VStack(alignment: .leading) {
                HStack {
                    Text(String(localized: "settings_buffer_size"))
                    Spacer()
                    Text("\(bufferMb) MB").foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(bufferMb) },
                        set: { bufferMb = Int($0) }
                    ),
                    in: bufferRange,
                    step: bufferStep,
                    onEditingChanged: { editing in
                        if !editing { KmpHelper.shared.setSendspinBufferCapacityMb(mb: Int32(bufferMb)) }
                    }
                )
                .disabled(enabled)
            }

            Toggle(String(localized: "settings_custom_sendspin"), isOn: $useCustomConnection)
                .disabled(enabled)
                .onChange(of: useCustomConnection) { _, newValue in KmpHelper.shared.setSendspinUseCustomConnection(enabled: newValue) }

            if useCustomConnection {
                TextField(String(localized: "settings_host"), text: $host)
                    .disabled(enabled)
                    .onChange(of: host) { _, newValue in KmpHelper.shared.setSendspinHost(host: newValue) }

                TextField(String(localized: "settings_port_default"), text: $port)
                    .keyboardType(.numberPad)
                    .disabled(enabled)
                    .onChange(of: port) { _, newValue in
                        if let value = Int32(newValue) { KmpHelper.shared.setSendspinPort(port: value) }
                    }

                TextField(String(localized: "settings_path"), text: $path)
                    .disabled(enabled)
                    .onChange(of: path) { _, newValue in KmpHelper.shared.setSendspinPath(path: newValue) }

                Toggle(String(localized: "settings_use_tls_wss"), isOn: $useTls)
                    .disabled(enabled)
                    .onChange(of: useTls) { _, newValue in KmpHelper.shared.setSendspinUseTls(enabled: newValue) }
            }

            Button(role: enabled ? .destructive : nil) {
                enabled.toggle()
                KmpHelper.shared.setSendspinEnabled(enabled: enabled)
            } label: {
                Text(String(localized: enabled ? "settings_disable_local_player" : "settings_enable_local_player"))
            }
        }
    }
}
