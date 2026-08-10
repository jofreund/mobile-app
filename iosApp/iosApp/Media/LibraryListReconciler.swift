import Foundation

/// A row the reconciler can match a server change against.
///
/// Deliberately the smallest possible surface — an id and the provider items behind it — so the
/// matching rules below can be tested without Kotlin types. `MediaItem` conforms in
/// `MediaItem.swift`.
protocol ReconcilableRow: Identifiable where ID == String {
    /// `provider:itemId`, the same shape `MediaItem.id` uses. Unique across providers, which a
    /// bare `itemId` is not — the library and a streaming provider can both hold id "1234".
    var id: String { get }

    /// `provider:itemId` for each of this row's provider mappings — the underlying items a
    /// library record was built from. Empty for rows that are already provider-level.
    var sourceIds: Set<String> { get }
}

/// Applies `MediaItemChange`s to a list that is already on screen.
///
/// Exists because the library list stopped refetching every time it was uncovered (that reload
/// was collapsing a paginated list back to its first page). Without a refetch, the only way a
/// favourite toggled from a detail page reaches the row behind it is a live change event, so this
/// is what keeps them in step.
///
/// Both operations are pure and total: they return a new array and never signal "not found",
/// because a change for something not on screen is the normal case, not an error.
enum LibraryListReconciler {

    /// Replaces every row carrying the changed item's identity.
    ///
    /// This is the favourite case, and the common one. `MediaItemUpdatedEvent` carries the same
    /// record the list is showing, so a plain id match is right — no provider-mapping fallback,
    /// which would risk overwriting a library row with a provider-level item that merely shares
    /// a source.
    static func applying<Row: ReconcilableRow>(_ updated: Row, to rows: [Row]) -> [Row] {
        guard rows.contains(where: { $0.id == updated.id }) else { return rows }
        return rows.map { $0.id == updated.id ? updated : $0 }
    }

    /// Drops every row the deletion refers to.
    ///
    /// The provider-mapping fallback is load-bearing rather than defensive. When the server
    /// announces that a *library record* is gone, `MediaItemRepository` deliberately re-keys the
    /// event to the record's first provider mapping — the underlying item still exists, and
    /// detail screens are supposed to fall through to it instead of dangling on a library id
    /// about to 404. The consequence here is that the id arriving on a deletion is **not** the id
    /// the library list is holding, so matching on `id` alone would silently drop every
    /// remove-from-library on the floor. Hence: match the row's own id, or any of its sources.
    static func removing<Row: ReconcilableRow>(_ deletedId: String, from rows: [Row]) -> [Row] {
        rows.filter { row in
            row.id != deletedId && !row.sourceIds.contains(deletedId)
        }
    }
}
