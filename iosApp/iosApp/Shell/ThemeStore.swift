import SwiftUI
import UIKit

/// The app's Dark / Light / Follow-System setting, applied to the UI.
///
/// The value lives in `AppPreferences`; this store is only its *application*.
///
/// **Applies via `UIWindow.overrideUserInterfaceStyle`, not `.preferredColorScheme`.** The first
/// attempt used the SwiftUI modifier, which is the more idiomatic API, and it half-worked: dark
/// stuck and you couldn't get back out of it — `.preferredColorScheme(nil)`, what Follow-System
/// has to resolve to, does not reliably clear an override SwiftUI has already applied to the
/// window. Setting the window style directly sidesteps that, and it's what the Kotlin code this
/// replaced (`ui/theme/SystemAppearance.ios.kt`) did — the one mechanism here with a track
/// record. It also covers presented content for free: a `fullScreenCover` like Settings or the
/// expanded player lives in the same window, whereas `.preferredColorScheme` needed the modifier
/// to sit above the presentation to reach it.
@Observable
@MainActor
final class ThemeStore {

    /// The stored setting. Also what Settings' theme picker renders from, so the segmented
    /// control tracks the value that actually took effect rather than re-reading it imperatively.
    private(set) var setting: ThemeSetting

    private let preferences: AppPreferences

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences
        // Seeded synchronously so the first frame is already correct rather than rendering light
        // and correcting itself.
        setting = preferences.theme
    }

    func start() {
        apply()
    }

    /// Write-through: persist, then apply. This store is the setting's only writer.
    func select(_ setting: ThemeSetting) {
        preferences.theme = setting
        self.setting = setting
        apply()
    }

    /// Re-assert the current setting. Called on every change, and again whenever the app becomes
    /// active so a window connected later (or restored) doesn't come back on the system style.
    func apply() {
        let style: UIUserInterfaceStyle = switch setting {
        case .dark: .dark
        case .light: .light
        case .followSystem: .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
