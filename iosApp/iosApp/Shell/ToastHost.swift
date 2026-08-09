import SwiftUI
import MusicAssistantKit

/// Native replacement for Compose's `ToastHost` — the display half of what
/// `FloatingBarSideEffectsController` existed to host.
///
/// Subscribes to `KmpHelper.toasts`, which merges the two sources that used to be collected
/// separately in Compose: `ErrorMessageBus` (server RPC errors) and the hint that the hardware
/// volume buttons don't reach a remote player. Deciding *what* deserves a toast stayed in Kotlin;
/// this owns only how it looks and how long it stays.
///
/// **Exactly one of these may exist.** The bus is a `Channel`, so a second subscriber wouldn't
/// duplicate messages — it would take some of them. The Compose host was mounted once per tab and
/// did precisely that, which is why an error could appear on a tab you weren't looking at. Mounted
/// once at the app root now (`AppShellRootView`), so it can't.
@Observable
@MainActor
final class ToastPresenter {

    private(set) var current: Toast?

    private var subscription: Cancellable?
    /// Identifies the dismissal that belongs to the toast on screen. A second message arriving
    /// mid-display replaces the first, and without this the first one's timer would then dismiss
    /// the *replacement* early.
    private var generation = 0

    struct Toast: Identifiable, Equatable {
        let id: Int
        let text: String
        let isLong: Bool

        /// Matches Compose's `ToastDuration`: SHORT 2s, LONG 3.5s.
        var duration: Duration { isLong ? .milliseconds(3500) : .milliseconds(2000) }
    }

    func start() {
        guard subscription == nil else { return }
        subscription = KmpHelper.shared.toasts.subscribe(
            onEach: { [weak self] message in
                guard let self, let message else { return }
                self.show(text: message.text, isLong: message.isLong)
            },
            onError: { error in
                // The flow is terminated at this point — nothing to retry against. Errors from
                // the merged sources aren't expected; log rather than fail silently.
                NativeLog.shared.error(
                    tag: "ToastPresenter",
                    message: "toast flow failed: \(error)"
                )
            }
        )
    }

    /// Not called today — the presenter is held by the app root and lives as long as the app.
    /// Kept so the subscription has a matching release if this ever moves somewhere narrower.
    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    private func show(text: String, isLong: Bool) {
        generation += 1
        let id = generation
        current = Toast(id: id, text: text, isLong: isLong)

        Task { [weak self] in
            try? await Task.sleep(for: isLong ? .milliseconds(3500) : .milliseconds(2000))
            guard let self, self.generation == id else { return }
            self.current = nil
        }
    }
}

/// Bottom-anchored transient message, styled after the Compose original (dark capsule, light
/// text) rather than as a system alert — it's incidental information, not something to dismiss.
private struct ToastView: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.8))
            )
            .padding(.horizontal, 24)
            // Purely informational, and it leaves on its own — a tap should reach whatever is
            // underneath rather than being swallowed by a message that's about to disappear.
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension View {

    /// Mount the app's single toast host. See `ToastPresenter` for why "single" matters.
    func toastHost(_ presenter: ToastPresenter) -> some View {
        overlay(alignment: .bottom) {
            if let toast = presenter.current {
                ToastView(text: toast.text)
                    // Sits above the tab bar and its accessory rather than behind them, which is
                    // where the Compose host's fixed-height backdrop had to live.
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: presenter.current)
        .task { presenter.start() }
    }
}
