import SwiftUI
import MusicAssistantKit

/// Settings. Replaced `SettingsScreen.kt` (1,309 LOC), which did double duty as both the
/// first-run/reconnect connection setup flow (host/port/TLS, WebRTC + QR scan, connection
/// history) and the authenticated settings screen. Connection setup and login/OAuth live in
/// `ConnectionSetupView`, wrapping (never reimplementing) `AuthenticationManager`'s real state
/// machine — server-ID-mismatch detection, per-server token lifecycle, and `SilentReauth`'s
/// bounded-retry-vs-surface-immediately asymmetry.
///
/// What the Compose original had and this doesn't: the Car actions / DSP sections — CarPlay
/// and Siri were removed outright, so there is nothing left for them to configure. The
/// Sendspin local-player config is back as `LocalPlayerSection` since the local player's
/// re-integration.
///
/// `KmpHelper.sessionState` exposes the real Kotlin `SessionState` sealed class directly (same
/// pattern `AppTabView.swift` already uses for `DeepLinkDestination`) so this view can branch on
/// the exact same states Compose does, rather than a flattened re-derivation that could drift.
struct SettingsView: View {

    @State private var sessionState: SessionState?
    @State private var subscription: Cancellable?

    /// Owned by `ContentView` — this screen is one of two readers, not the source of truth.
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if let connected = sessionState as? SessionState.Connected,
                   let authenticated = connected.dataConnectionState as? DataConnectionStateAuthenticated {
                    nativeContent(connected: connected, authenticated: authenticated)
                } else {
                    ConnectionSetupView(sessionState: sessionState)
                }
            }
            .navigationTitle(String(localized: "nav_settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // An ✕, not a back chevron: this is presented over the app as a modal now,
                    // so there's nothing behind it to go "back" to. Still `requestHome()` —
                    // the router owns the destination, and flipping it is what dismisses.
                    Button {
                        AppRouter.shared.requestHome()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(String(localized: "common_close"))
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
            SettingsServerInfoSection(connected: connected)
            if let user = connected.user {
                accountSection(user: user)
            }
            LocalPlayerSection()
            themeSection
            LiveActivitySection()
            miscSection
        }
    }

    // MARK: - Account

    private func accountSection(user: User) -> some View {
        Section(String(localized: "auth_title")) {
            Text(String(format: String(localized: "auth_logged_in_as"), user.description_))
            Button(String(localized: "auth_logout")) {
                _ = KmpHelper.shared.authLogout {}
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
                Image(systemName: "circle.lefthalf.filled").tag(ThemeSetting.followSystem)
                Image(systemName: "moon").tag(ThemeSetting.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Reads and writes `ThemeStore` rather than `AppPreferences` directly, so the window style
    /// is applied in the same step as the value changes.
    private var themeBinding: Binding<ThemeSetting> {
        Binding(
            get: { theme.setting },
            set: { theme.select($0) }
        )
    }

    // MARK: - Misc / logs

    private var miscSection: some View {
        MiscLogsSection()
    }
}

/// Whether the lock screen / Dynamic Island Live Activity is on screen for the selected player
/// at all times, or only while something is playing. Isolated like `MiscLogsSection` so its
/// `@State` doesn't live on `SettingsView`.
///
/// Binds straight to `AppPreferences`. `PlayerActivityController` observes the very same
/// property, so it reacts to the change without this view knowing it exists.
private struct LiveActivitySection: View {

    private let preferences = AppPreferences.shared

    var body: some View {
        Section {
            // Inline, so both choices are visible rows under the header rather than a
            // push-to-a-sub-screen row whose own label would just repeat that header.
            Picker("", selection: binding) {
                Text(String(localized: "settings_live_activity_always"))
                    .tag(LiveActivityVisibility.always)
                Text(String(localized: "settings_live_activity_while_playing"))
                    .tag(LiveActivityVisibility.whilePlaying)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(String(localized: "settings_live_activity"))
        } footer: {
            Text(String(localized: "settings_live_activity_explanation"))
        }
    }

    private var binding: Binding<LiveActivityVisibility> {
        Binding(
            get: { preferences.liveActivityVisibility },
            set: { preferences.liveActivityVisibility = $0 }
        )
    }
}

/// Shared between `SettingsView.nativeContent` (authenticated) and `ConnectionSetupView`
/// (connected but not-yet-authenticated) — Compose shows this section for *any* `Connected`
/// state, not just the authenticated one, so both native call sites reuse it verbatim rather
/// than duplicating the Direct/WebRTC info text or the disconnect button.
struct SettingsServerInfoSection: View {

    let connected: SessionState.Connected

    var body: some View {
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
