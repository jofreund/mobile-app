import SwiftUI
import MusicAssistantKit

/// Owns the subscription for as long as the view's state does, and cancels it in `deinit`.
///
/// Deliberately **not** tied to `onAppear`/`onDisappear`. Pushing a detail page makes the list
/// disappear, and the change this observer exists to catch — a favourite toggled on that detail
/// page — arrives precisely while it is gone. A subscription that stopped at `onDisappear` would
/// miss the one event it was added for and reintroduce the staleness it is meant to remove.
///
/// `@State` keeps this box alive across the push and releases it when the screen is really gone,
/// which makes `deinit` the honest cancellation point.
private final class ChangeSubscription: @unchecked Sendable {
    var cancellable: Cancellable?
    deinit { cancellable?.cancel() }
}

private struct LibraryChangeObserver: ViewModifier {

    @Binding var items: [MediaItem]?
    @State private var subscription = ChangeSubscription()

    func body(content: Content) -> some View {
        content.onAppear {
            guard subscription.cancellable == nil else { return }
            subscription.cancellable = KmpHelper.shared.itemChanges.subscribe(
                onEach: { change in apply(change) },
                onError: { error in
                    // A flow that throws is terminated, so there is nothing left to reconcile
                    // from. Logged rather than surfaced: the list still shows correct data, it
                    // has only stopped tracking changes, and a pull-to-refresh recovers it.
                    NativeLog.shared.warn(
                        tag: "LibraryChangeObserver",
                        message: "itemChanges failed: \(error.message ?? "unknown")"
                    )
                }
            )
        }
    }

    private func apply(_ change: MediaItemChange?) {
        guard let change, let current = items else { return }
        let reconciled: [MediaItem]

        switch change {
        case let updated as MediaItemChange.Updated:
            reconciled = LibraryListReconciler.applying(MediaItem(updated.item), to: current)
        case let deleted as MediaItemChange.Deleted:
            let id = "\(deleted.item.provider):\(deleted.item.itemId)"
            reconciled = LibraryListReconciler.removing(id, from: current)
        default:
            // `Added` deliberately does nothing. This list is sorted, filtered and paginated
            // server-side, so there is no position a new item could be inserted at that would be
            // right — and a guess is something the next page load then contradicts. Pull to
            // refresh is the honest way to see it.
            return
        }

        // Most changes are for something this list has never heard of, so this is usually where
        // it stops. Comparing first keeps those from writing state and re-rendering the grid.
        guard reconciled != current else { return }
        items = reconciled
    }
}

extension View {
    /// Keeps a list of library rows in step with server-side changes — favourites toggled from a
    /// detail page, items removed from the library — without refetching.
    ///
    /// This exists because the library list stopped reloading every time it was uncovered: that
    /// reload was collapsing a paginated list back to its first page and blanking the screen
    /// (`b72260b9`). Refetching was the only thing keeping rows current, so something had to
    /// replace it.
    func observingLibraryChanges(_ items: Binding<[MediaItem]?>) -> some View {
        modifier(LibraryChangeObserver(items: items))
    }
}
