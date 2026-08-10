import XCTest

// `LibraryListReconciler.swift` is compiled into this target directly — `iosAppTests` has no host
// application, so there is no `iosApp` module to import. See DEV-ENVIRONMENT.md.

/// A stand-in for `MediaItem`. The rules under test are about identity, not about media, and a
/// stub keeps them exercisable without the Kotlin bridge.
private struct Row: ReconcilableRow, Equatable {
    let id: String
    var sourceIds: Set<String> = []
    var favorite = false
}

final class LibraryListReconcilerTests: XCTestCase {

    private let rows = [
        Row(id: "library:1", sourceIds: ["spotify:aaa"]),
        Row(id: "library:2", sourceIds: ["spotify:bbb", "filesystem:/music/b.flac"]),
        Row(id: "library:3"),
    ]

    // MARK: - Updates

    /// The favourite case: the server echoes the same record with a new flag on it.
    func testUpdateReplacesTheMatchingRow() {
        let updated = Row(id: "library:2", sourceIds: ["spotify:bbb"], favorite: true)

        let result = LibraryListReconciler.applying(updated, to: rows)

        XCTAssertEqual(result.count, 3, "an update must not change the length")
        XCTAssertEqual(result[1], updated)
        XCTAssertEqual(result.map(\.id), rows.map(\.id), "order must be preserved")
    }

    func testUpdateForSomethingNotOnScreenChangesNothing() {
        let result = LibraryListReconciler.applying(Row(id: "library:99"), to: rows)

        XCTAssertEqual(result, rows)
    }

    /// Matching is by id only. A provider-level item that merely shares a source with a library
    /// row must not overwrite that row — they are different records.
    func testUpdateDoesNotMatchOnProviderMappings() {
        let sourceLevel = Row(id: "spotify:bbb", favorite: true)

        let result = LibraryListReconciler.applying(sourceLevel, to: rows)

        XCTAssertEqual(result, rows)
    }

    // MARK: - Deletions

    /// The reason the fallback exists. `MediaItemRepository` re-keys a deleted library record to
    /// its first provider mapping, so the id that arrives is never the id the list is holding —
    /// matching on `id` alone would drop every remove-from-library silently.
    func testDeletionMatchesTheRowsProviderMapping() {
        let result = LibraryListReconciler.removing("spotify:bbb", from: rows)

        XCTAssertEqual(result.map(\.id), ["library:1", "library:3"])
    }

    func testDeletionMatchesAnyMappingNotJustTheFirst() {
        let result = LibraryListReconciler.removing("filesystem:/music/b.flac", from: rows)

        XCTAssertEqual(result.map(\.id), ["library:1", "library:3"])
    }

    /// A provider-level list gets deletions keyed to the row itself.
    func testDeletionMatchesTheRowsOwnId() {
        let result = LibraryListReconciler.removing("library:3", from: rows)

        XCTAssertEqual(result.map(\.id), ["library:1", "library:2"])
    }

    func testDeletionOfSomethingNotOnScreenChangesNothing() {
        XCTAssertEqual(LibraryListReconciler.removing("spotify:zzz", from: rows), rows)
    }

    /// One source shared by two library rows should take both, since both records are gone.
    func testDeletionRemovesEveryRowThatClaimsTheSource() {
        let shared = [
            Row(id: "library:1", sourceIds: ["spotify:same"]),
            Row(id: "library:2", sourceIds: ["spotify:same"]),
            Row(id: "library:3", sourceIds: ["spotify:other"]),
        ]

        let result = LibraryListReconciler.removing("spotify:same", from: shared)

        XCTAssertEqual(result.map(\.id), ["library:3"])
    }

    func testEmptyListsAreHandled() {
        XCTAssertEqual(LibraryListReconciler.applying(Row(id: "a"), to: []), [])
        XCTAssertEqual(LibraryListReconciler.removing("a", from: [Row]()), [])
    }
}
