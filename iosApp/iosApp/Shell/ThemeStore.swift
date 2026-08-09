import SwiftUI
import UIKit
import MusicAssistantKit

/// The app's Dark / Light / Follow-System setting, applied to the UI.
///
/// The setting itself stays in Kotlin — persisted in `SettingsRepository`, read here through
/// `KmpHelper.themeSetting`. Only its *application* is native.
///
/// **Applies via `UIWindow.overrideUserInterfaceStyle`, not `.preferredColorScheme`.** The first
/// attempt used the SwiftUI modifier, which is the more idiomatic API, and it half-worked: dark
/// stuck and you couldn't get back out of it. Two things plausibly caused that and the fix is the
/// same for both, so it isn't worth distinguishing them —
///
/// 1. `.preferredColorScheme(nil)` — what Follow-System has to resolve to — does not reliably
///    clear an override SwiftUI has already applied to the window.
/// 2. `ThemeSetting` is a bridged Kotlin enum, i.e. an ObjC class with singleton members rather
///    than a Swift enum, so a `switch` over it matches by object identity. If a case failed to
///    match it would silently fall to the default and return `nil` — landing on (1) anyway.
///
/// Setting the window style directly sidesteps both, and it's what the Kotlin code this replaced
/// (`ui/theme/SystemAppearance.ios.kt`) did — the one mechanism here with a track record. It also
/// covers presented content for free: a `fullScreenCover` like Settings or the expanded player
/// lives in the same window, whereas `.preferredColorScheme` needed the modifier to sit above the
/// presentation to reach it.
@Observable
@MainActor
final class ThemeStore {

    /// The stored setting. Also what Settings' theme picker renders from, so the segmented
    /// control tracks the value that actually took effect rather than re-reading it imperatively.
    private(set) var setting: ThemeSetting

    private var subscription: Cancellable?

    init() {
        // Seeded synchronously so the first frame is already correct rather than rendering light
        // and correcting itself. `NativeStateFlow` exposes `value` for exactly this.
        setting = KmpHelper.shared.themeSetting.value ?? .followsystem
    }

    func start() {
        apply()
        guard subscription == nil else { return }
        subscription = KmpHelper.shared.themeSetting.subscribe { [weak self] setting in
            guard let self, let setting else { return }
            self.setting = setting
            self.apply()
        }
    }

    /// Write-through. The new value arrives back via the subscription, which is what triggers
    /// [apply] — so nothing is set locally and there's one source of truth. The UI can't show a
    /// choice the repository rejected.
    func select(_ setting: ThemeSetting) {
        KmpHelper.shared.switchTheme(theme: setting)
    }

    /// Re-assert the current setting. Called on every change, and again whenever the app becomes
    /// active so a window connected later (or restored) doesn't come back on the system style.
    func apply() {
        let style = Self.style(for: setting)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    /// Explicit `==` rather than a `switch` with a `default:`. These are bridged Kotlin enum
    /// singletons, and a `default:` would turn "this comparison didn't work" into a silent
    /// Follow-System — which is precisely the failure that would be hardest to spot.
    private static func style(for setting: ThemeSetting) -> UIUserInterfaceStyle {
        if setting == ThemeSetting.dark { return .dark }
        if setting == ThemeSetting.light { return .light }
        return .unspecified  // .followsystem
    }
}
