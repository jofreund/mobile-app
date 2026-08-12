import Foundation

/// One media-type group of search results — the thing a filter chip names.
///
/// Split out of `SearchView` so the chips' rule for what to show can be tested: `iosAppTests`
/// has no host application and links only Foundation, so this file is compiled into both
/// targets (DEV-ENVIRONMENT.md) and therefore names neither SwiftUI nor MusicAssistantKit.
/// That is also why it is generic over its item type instead of holding `MediaItem` directly —
/// the item type is the only thing here that would drag the Kotlin framework in, and none of
/// this logic ever looks inside an item.
struct SearchSection<Item>: Identifiable {

    /// Stable across searches — "tracks", "albums" and so on, never a position — because a chip
    /// selection is stored as one of these ids and has to keep naming the same group when the
    /// next result set arrives with a different set of groups in it.
    let id: String

    let title: String

    let items: [Item]
}

/// The chips' logic, with no view attached.
enum SearchSections {

    /// The groups worth a chip, in the order given: whichever of them has results.
    ///
    /// Order is the caller's, not this function's, so the chip row and the section headers stay
    /// in the fixed order `SearchViewModel.SearchResults.nonEmptyLists` established rather than
    /// reshuffling per query.
    static func nonEmpty<Item>(_ groups: [SearchSection<Item>]) -> [SearchSection<Item>] {
        groups.filter { !$0.items.isEmpty }
    }

    /// The one group a chip selection names, or all of them when `selection` is nil ("All").
    ///
    /// A selection that no longer names any group falls back to showing all of them rather than
    /// an empty screen — the case a newer search creates when it returns nothing of the type the
    /// previous chip named.
    static func visible<Item>(
        _ sections: [SearchSection<Item>],
        selection: String?
    ) -> [SearchSection<Item>] {
        guard let selection,
              let chosen = sections.first(where: { $0.id == selection })
        else { return sections }
        return [chosen]
    }
}
