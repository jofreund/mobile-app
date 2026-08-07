import SwiftUI
import ComposeApp

/// Drives the top-level switch that used to live entirely in Compose
/// (`TopLevelNavRoot.kt`): which screen is showing (the main tab shell vs.
/// connection setup), whether the cold-launch auto-login splash is up, and
/// whether a reconnection banner should show.
///
/// Deliberately thin — every actual decision (which screen a session-state
/// transition forces, when the splash latches closed) lives in Kotlin's
/// `AppRootRouter`, reached through `KmpHelper`'s `NativeStateFlow`
/// properties. This class only turns those into `@Observable` state SwiftUI
/// can bind to; see `AppRootRouter`'s doc for why the policy itself isn't
/// duplicated here.
@Observable
@MainActor
final class AppRouter {

    private(set) var destination: AppRootDestination = .main
    private(set) var splashVisible = false
    private(set) var bannerState: AppBannerState?
    private(set) var schemaWarning: SchemaWarning?

    private var destinationSubscription: Cancellable?
    private var splashSubscription: Cancellable?
    private var bannerSubscription: Cancellable?
    private var schemaWarningSubscription: Cancellable?

    /// Starts observing. Call once — from the root view's `.task`, so the
    /// subscriptions live exactly as long as the app does; there is only ever
    /// one `AppRouter`.
    func start() {
        guard destinationSubscription == nil else { return }

        destinationSubscription = KmpHelper.shared.rootDestination.subscribe { [weak self] value in
            // AppRootRouter.destination is a non-null StateFlow; the Optional
            // here is only NativeStateFlow's uniform (nullable-or-not) shape.
            guard let value else { return }
            self?.destination = value
        }

        splashSubscription = KmpHelper.shared.splashVisible.subscribe { [weak self] value in
            self?.splashVisible = value?.boolValue ?? false
        }

        bannerSubscription = KmpHelper.shared.connectionBannerState.subscribe { [weak self] value in
            self?.bannerState = value
        }

        schemaWarningSubscription = KmpHelper.shared.schemaWarning.subscribe { [weak self] value in
            self?.schemaWarning = value
        }
    }

    func stop() {
        destinationSubscription?.cancel()
        splashSubscription?.cancel()
        bannerSubscription?.cancel()
        schemaWarningSubscription?.cancel()
        destinationSubscription = nil
        splashSubscription = nil
        bannerSubscription = nil
        schemaWarningSubscription = nil
    }

    /// Cancels the in-flight auto-login attempt (splash's Cancel button).
    func cancelAutoLogin() {
        KmpHelper.shared.cancelAutoLogin()
    }

    /// Tears down the connection so the reconnection banner's Cancel button
    /// stops the retry loop, matching `ConnectionStatusBanner.kt`'s `onCancel`.
    func cancelReconnect() {
        KmpHelper.shared.serviceClient.disconnectByUser()
    }
}
