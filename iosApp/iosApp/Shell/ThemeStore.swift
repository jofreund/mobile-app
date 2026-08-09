import SwiftUI
import ComposeApp

/// The app's Dark / Light / Follow-System setting, as something SwiftUI can render.
///
/// This is Phase C's deferred "SwiftUI owns `.preferredColorScheme`" inversion, finally done —
/// and by the time it landed it wasn't optional. Applying the theme had been Kotlin's job:
/// `ui/theme/SystemAppearance.ios.kt` set `overrideUserInterfaceStyle` on every `UIWindow`, from
/// inside a `@Composable`, so it ran only while a Compose host was mounted. Once the last host
/// went away there was nothing left applying the setting at all.
///
/// The setting itself stays in Kotlin — it's persisted in `SettingsRepository` and read by
/// `KmpHelper.theme()` elsewhere. Only its *application* moved.
@Observable
@MainActor
final class ThemeStore {

    /// The stored setting. Also what Settings' theme picker renders from, so the segmented
    /// control tracks the value that actually took effect rather than re-reading it imperatively.
    private(set) var setting: ThemeSetting

    /// What to hand `.preferredColorScheme`. `nil` means "follow the system", which is exactly
    /// what that modifier does with `nil` — so Follow-System needs no special case downstream.
    var colorScheme: ColorScheme? {
        switch setting {
        case .dark: .dark
        case .light: .light
        default: nil  // .followsystem — don't override
        }
    }

    private var subscription: Cancellable?

    init() {
        // Seeded synchronously so the first frame is already in the right scheme rather than
        // rendering light and correcting itself. `NativeStateFlow` exposes `value` for this.
        setting = KmpHelper.shared.themeSetting.value ?? .followsystem
    }

    func start() {
        guard subscription == nil else { return }
        subscription = KmpHelper.shared.themeSetting.subscribe { [weak self] setting in
            guard let self, let setting else { return }
            self.setting = setting
        }
    }

    /// Write-through. The new value arrives back via the subscription, so nothing is set locally
    /// — one source of truth, and the UI can't show a choice the repository rejected.
    func select(_ setting: ThemeSetting) {
        KmpHelper.shared.switchTheme(theme: setting)
    }
}
