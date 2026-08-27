import SwiftUI
import MusicAssistantKit

/// Phase E4, part 2 — the native replacement for the Compose `SettingsScreen` fallback that
/// used to render for every `SessionState` except `Connected` + `Authenticated`. Mirrors
/// `SettingsScreen.kt`'s own composition exactly: `Disconnected` shows the connect forms +
/// history; `Connecting`/`Reconnecting` shows a spinner; any `Connected` state (even before
/// authentication) shows server info + the login/OAuth panel. All actual state-machine
/// decisions live in `ConnectionSetupStore`/`AuthenticationManager` — this file is UI only.
struct ConnectionSetupView: View {

    let sessionState: SessionState?

    @State private var store = ConnectionSetupStore()
    @State private var showHistorySheet = false
    @State private var showQrScan = false
    @State private var selectedProviderIndex = 0
    @State private var isPasswordVisible = false

    var body: some View {
        Form {
            content
        }
        .task { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: sessionStateTag, initial: true) {
            store.onSessionStateChange(sessionState)
        }
        .onChange(of: store.providers.map(\.id)) {
            selectedProviderIndex = 0
        }
        .sheet(isPresented: $showHistorySheet) {
            ConnectionHistorySheet(
                history: store.history,
                onFill: { store.fillFromHistory($0); showHistorySheet = false },
                onDelete: store.removeFromHistory
            )
        }
        .sheet(isPresented: $showQrScan) {
            QrScanView { store.remoteId = $0 }
        }
    }

    /// `.onChange` needs an `Equatable` key; Kotlin-bridged sealed-class instances aren't
    /// automatically `Equatable` in Swift. A type-name tag is coarse — it doesn't
    /// distinguish `AwaitingAuth` sub-states (`NotStarted`/`InProgress`/`Failed`) that share
    /// the same outer `SessionState.ConnectedDirect`/`ConnectedWebRTC` class — but that's fine
    /// here: `onSessionStateChange`'s only state-dependent action (loading providers) needs to
    /// fire exactly once on *entering* the `Connected` regime, which a type change always
    /// captures; sub-state transitions within it correctly need no further action. The one
    /// scenario a coarse tag could miss — `needsServerReauth` bouncing `Authenticated` back to
    /// `AwaitingAuth` without changing the outer type — instead tears this whole view down and
    /// recreates it (`SettingsView`'s `nativeContent`/`ConnectionSetupView` switch), so the
    /// `initial: true` firing on the fresh instance covers it.
    private var sessionStateTag: String {
        sessionState.map { String(describing: type(of: $0)) } ?? "nil"
    }

    @ViewBuilder
    private var content: some View {
        if let state = sessionState {
            switch state {
            case is SessionState.Disconnected:
                connectionTabsSection(state: state)
            case is SessionState.Connecting, is SessionState.Reconnecting:
                connectingSection
            case let connected as SessionState.Connected:
                SettingsServerInfoSection(connected: connected)
                authPanelSection(connected: connected)
            default:
                Section {
                    Text(String(localized: "settings_connecting"))
                }
            }
        } else {
            Section {
                ProgressView()
            }
        }
    }

    // MARK: - Disconnected: connection setup

    @ViewBuilder
    private func connectionTabsSection(state: SessionState) -> some View {
        Section {
            Text(String(localized: "settings_about_description"))
                .font(.subheadline)
            Link(String(localized: "settings_about_learn_more"), destination: URL(string: "https://music-assistant.io")!)
                .font(.subheadline)
        }

        Section {
            Picker(String(localized: "settings_connection_method"), selection: methodBinding) {
                Text(String(localized: "settings_connection_direct")).tag("direct")
                Text(String(localized: "settings_connection_webrtc")).tag("webrtc")
            }
            .pickerStyle(.segmented)
            if store.preferredMethod == "webrtc" {
                Text(String(localized: "settings_connection_experimental"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if store.preferredMethod == "webrtc" {
            webrtcSection
        } else {
            directSection
        }

        if let errorText = disconnectedErrorText(state) {
            Section {
                Text(errorText).foregroundStyle(.red)
            }
        }
    }

    private var methodBinding: Binding<String> {
        Binding(get: { store.preferredMethod }, set: { store.setPreferredMethod($0) })
    }

    private func disconnectedErrorText(_ state: SessionState) -> String? {
        guard let disconnectedError = state as? SessionState.DisconnectedError,
              let reason = disconnectedError.reason
        else { return nil }
        if reason is ServerIdMismatchException {
            return String(localized: "server_id_mismatch_error")
        }
        return reason.message
    }

    @ViewBuilder
    private var directSection: some View {
        Section {
            // Prompts come from the same shared-core Defaults the fields are seeded with, so
            // clearing a field hints at exactly what it started as.
            TextField(String(localized: "settings_server_host"), text: $store.host, prompt: Text(Defaults.shared.URI))
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField(String(localized: "settings_port"), text: $store.port, prompt: Text(String(Defaults.shared.PORT)))
                .keyboardType(.numberPad)
            Toggle(String(localized: "settings_use_tls"), isOn: $store.isTls)
            HStack {
                Button {
                    store.attemptConnection()
                } label: {
                    Text(String(localized: store.hasCredentialsForDirect() ? "settings_connect_saved" : "settings_connect"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(store.host.isValidHost && store.port.isIpPort))

                Button {
                    showHistorySheet = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel(String(localized: "cd_connection_history"))
            }
        }
    }

    @ViewBuilder
    private var webrtcSection: some View {
        Section {
            Text(String(localized: "settings_webrtc_description"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "settings_webrtc_disclaimer"))
                .font(.caption)
                .foregroundStyle(.blue)

            HStack {
                TextField(String(localized: "settings_remote_id"), text: remoteIdBinding, prompt: Text("XXXXXXXX-XXXXX-XXXXX-XXXXXXXX"))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button {
                    showQrScan = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .accessibilityLabel(String(localized: "cd_scan_qr_code"))
            }
            if !store.remoteId.isEmpty && !store.remoteId.isValidRemoteId {
                Text(String(localized: "settings_remote_id_invalid"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(String(localized: "settings_remote_id_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(localized: "settings_webrtc_info"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    store.attemptWebRTCConnection()
                } label: {
                    Text(webrtcConnectLabel).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.remoteId.isEmpty || !store.remoteId.isValidRemoteId || isWebRTCConnected || isConnecting)

                Button {
                    showHistorySheet = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel(String(localized: "cd_connection_history"))
            }
        }
    }

    private var remoteIdBinding: Binding<String> {
        Binding(get: { store.remoteId }, set: { store.remoteId = $0.uppercased() })
    }

    private var isWebRTCConnected: Bool { sessionState is SessionState.ConnectedWebRTC }
    private var isConnecting: Bool { sessionState is SessionState.Connecting }

    private var webrtcConnectLabel: String {
        if isWebRTCConnected { return String(localized: "settings_connected") }
        if isConnecting { return String(localized: "settings_connecting") }
        if store.hasCredentialsForWebRTC() { return String(localized: "settings_connect_saved") }
        return String(localized: "settings_connect_webrtc")
    }

    // MARK: - Connecting / Reconnecting

    @ViewBuilder
    private var connectingSection: some View {
        Section {
            VStack(spacing: 12) {
                if store.preferredMethod == "webrtc" {
                    Text(String(localized: "settings_connecting_remote"))
                } else {
                    Text(String(format: String(localized: "settings_connecting_to"), store.host, store.port))
                }
                Button(String(localized: "common_cancel")) {
                    KmpHelper.shared.serviceClient.disconnectByUser()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Connected, not yet authenticated: login/OAuth panel

    @ViewBuilder
    private func authPanelSection(connected: SessionState.Connected) -> some View {
        if let user = connected.user {
            Section(String(localized: "auth_title")) {
                Text(String(format: String(localized: "auth_logged_in_as"), user.description_))
                Button(String(localized: "auth_logout")) { store.logout() }
            }
        } else if store.providers.isEmpty {
            Section(String(localized: "auth_title")) {
                Text(String(localized: "auth_loading_providers"))
                Button(String(localized: "auth_retry_providers")) { store.loadProviders() }
            }
        } else {
            Section(String(localized: "auth_title")) {
                providerPicker
            }
        }

        if store.authState is AuthState.Loading {
            Section {
                HStack {
                    Spacer()
                    Text(String(localized: "auth_authenticating"))
                    Spacer()
                }
            }
        }

        if let error = store.loginError {
            Section {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var providerPicker: some View {
        if store.providers.count > 1 {
            Picker("", selection: $selectedProviderIndex) {
                ForEach(Array(store.providers.enumerated()), id: \.offset) { index, provider in
                    Text(providerLabel(provider)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if store.providers.indices.contains(selectedProviderIndex) {
            let provider = store.providers[selectedProviderIndex]
            switch provider.type {
            case "builtin":
                builtinLoginForm(provider: provider)
            case "homeassistant":
                Button(String(localized: "auth_authorize_ha")) {
                    store.login(provider: provider)
                }
                .disabled(store.authState is AuthState.Loading)
            default:
                EmptyView()
            }
        }
    }

    /// Hardcoded, not localized — matches `AuthenticationPanel`'s own tab labels, which are
    /// literal strings in the Kotlin source rather than server-supplied or `stringResource`.
    private func providerLabel(_ provider: AuthProvider) -> String {
        provider.type == "builtin" ? "Music Assistant" : "Home Assistant"
    }

    @ViewBuilder
    private func builtinLoginForm(provider: AuthProvider) -> some View {
        TextField(String(localized: "auth_username"), text: $store.username)
            .textContentType(.username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

        HStack {
            Group {
                if isPasswordVisible {
                    TextField(String(localized: "auth_password"), text: $store.password)
                } else {
                    SecureField(String(localized: "auth_password"), text: $store.password)
                }
            }
            .textContentType(.password)
            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: isPasswordVisible ? "auth_hide_password" : "auth_show_password"))
        }

        Button(String(localized: "auth_login")) {
            store.login(provider: provider)
        }
        .disabled(store.username.isEmpty || store.password.isEmpty)
    }
}

/// Native counterpart to `ConnectionHistoryDialog`. Tapping a row fills the connect form
/// (never auto-connects); swipe-to-delete removes the entry and its saved token.
private struct ConnectionHistorySheet: View {

    let history: [ConnectionHistoryEntry]
    let onFill: (ConnectionHistoryEntry) -> Void
    let onDelete: (ConnectionHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.isEmpty {
                    ContentUnavailableView(
                        String(localized: "settings_no_saved_connections"),
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    List {
                        ForEach(history, id: \.serverIdentifier) { entry in
                            Button {
                                onFill(entry)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.displayAddress)
                                    Text(String(localized: entry.type == .direct ? "settings_history_direct" : "settings_history_webrtc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    onDelete(entry)
                                } label: {
                                    Label(String(localized: "common_delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "settings_saved_connections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_cancel")) { dismiss() }
                }
            }
        }
    }
}
