import SwiftUI
import MusicAssistantKit

/// The Library tab's root — a table of categories (Artists, Albums, Titel, …, Durchsuchen).
/// `LibraryCategoriesViewModel` was a thin pass-through over
/// `SettingsRepository.libraryCategoryConfig` (no session state, no server round trip — the
/// category list itself is a fixed Kotlin enum), so there's nothing worth wrapping: this screen
/// reads/writes that config directly via `KmpHelper.libraryCategoryConfig`/
/// `setLibraryCategoryConfig`, same shape `HomeView.swift` uses for `homeRowsConfig`.
///
/// Edit mode mirrors `HomeView.swift`'s: two native `List` sections (Enabled — reorderable via
/// `.onMove`; Disabled — toggle-only) instead of Compose's single index-clamped-drag
/// `LazyVerticalGrid`, producing the same end result without replicating its drag-index
/// clamping or its tap-swallow-but-allow-drag gesture scrim.
struct LibraryView: View {

    @State private var config: [SettingsRepository.LibraryCategoryPref] = []
    @State private var isEditing = false
    @State private var editingEnabledRows: [LibraryCategoryRow] = []
    @State private var editingDisabledRows: [LibraryCategoryRow] = []

    private var rows: [(row: LibraryCategoryRow, enabled: Bool)] {
        reconciledCategories(config: config)
    }

    var body: some View {
        content
            .navigationTitle(String(localized: "nav_library"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { editButton }
            }
            .task { config = KmpHelper.shared.libraryCategoryConfig() }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            editingList
        } else {
            // A table rather than the tile grid this started as. The grid was a fairly direct
            // read of Compose's `GridButton` layout; a list is what Apple Music's own Library
            // root uses, and it reads better for a short, fixed set of text destinations.
            // `.plain` for the same reason — edge-to-edge separators, not inset cards.
            List(rows.filter(\.enabled).map(\.row)) { row in
                categoryLink(row)
            }
            .listStyle(.plain)
        }
    }

    /// Real `NavigationLink`s, so each row gets the system disclosure indicator and the standard
    /// highlight for free. This screen used to take `onNavigateToLibraryCategory`/
    /// `onNavigateToBrowse` closures and push through the parent, which predates these routes
    /// being registered on the Library stack — `AppTabView` was appending exactly the values
    /// built here, one indirection later.
    @ViewBuilder
    private func categoryLink(_ row: LibraryCategoryRow) -> some View {
        if row.category == .browse {
            NavigationLink(value: BrowseRoute(path: nil, title: nil)) { categoryLabel(row) }
        } else if let mediaType = row.category.mediaType {
            NavigationLink(value: LibraryCategoryRoute(mediaType: mediaType)) { categoryLabel(row) }
        }
    }

    private func categoryLabel(_ row: LibraryCategoryRow) -> some View {
        Label {
            Text(row.title)
                .font(.body)
        } icon: {
            Image(systemName: row.category.symbolName)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Toolbar

    private var editButton: some View {
        Button {
            if isEditing {
                commitEdits()
            } else {
                beginEditing()
            }
        } label: {
            Image(systemName: isEditing ? "checkmark" : "pencil")
        }
        .accessibilityLabel(String(localized: isEditing ? "common_done" : "cd_customize_tabs"))
    }

    // MARK: - Edit mode

    private func beginEditing() {
        editingEnabledRows = rows.filter(\.enabled).map(\.row)
        editingDisabledRows = rows.filter { !$0.enabled }.map(\.row)
        isEditing = true
    }

    private func commitEdits() {
        let newConfig =
            editingEnabledRows.map { SettingsRepository.LibraryCategoryPref(name: $0.category.name, enabled: true) } +
            editingDisabledRows.map { SettingsRepository.LibraryCategoryPref(name: $0.category.name, enabled: false) }
        KmpHelper.shared.setLibraryCategoryConfig(config: newConfig)
        config = newConfig
        isEditing = false
    }

    private var editingList: some View {
        List {
            Section {
                ForEach(editingEnabledRows) { row in
                    editingRow(row, enabled: true)
                }
                .onMove { editingEnabledRows.move(fromOffsets: $0, toOffset: $1) }
            }
            if !editingDisabledRows.isEmpty {
                Section {
                    ForEach(editingDisabledRows) { row in
                        editingRow(row, enabled: false)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private func editingRow(_ row: LibraryCategoryRow, enabled: Bool) -> some View {
        HStack {
            Image(systemName: row.category.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(row.title)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { enabled },
                    set: { newValue in toggleEnabled(row, newValue: newValue) }
                )
            )
            .labelsHidden()
            // Can't disable the only remaining enabled category, matching the Compose original.
            .disabled(enabled && editingEnabledRows.count <= 1)
        }
    }

    private func toggleEnabled(_ row: LibraryCategoryRow, newValue: Bool) {
        if newValue {
            editingDisabledRows.removeAll { $0.id == row.id }
            editingEnabledRows.append(row)
        } else {
            editingEnabledRows.removeAll { $0.id == row.id }
            editingDisabledRows.insert(row, at: 0)
        }
    }
}

/// One library category — mirrors Compose's `(LibraryCategory, Boolean)` pairing, narrowed to
/// what this screen needs for display.
struct LibraryCategoryRow: Identifiable, Equatable {
    let category: LibraryCategory
    var id: String { category.name }
    var title: String { category.searchFilterLabel }

    static func == (lhs: LibraryCategoryRow, rhs: LibraryCategoryRow) -> Bool { lhs.id == rhs.id }
}

/// Ported 1:1 from `LibraryCategoryConfig.kt`'s `reconcileLibraryCategories`: every
/// `LibraryCategory` case, enabled/ordered per [config] — categories never in [config] default
/// to enabled, in their natural declaration order.
private func reconciledCategories(config: [SettingsRepository.LibraryCategoryPref]) -> [(row: LibraryCategoryRow, enabled: Bool)] {
    let enabledById = Dictionary(config.map { ($0.name, $0.enabled) }, uniquingKeysWith: { first, _ in first })
    let orderById = Dictionary(config.enumerated().map { (offset, pref) in (pref.name, offset) }, uniquingKeysWith: { first, _ in first })

    return LibraryCategory.entries
        .map { category in (row: LibraryCategoryRow(category: category), enabled: enabledById[category.name] ?? true) }
        .sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            return (orderById[lhs.row.id] ?? Int.max) < (orderById[rhs.row.id] ?? Int.max)
        }
}

private extension LibraryCategory {
    /// Same SF Symbol set `MediaItem.Kind.symbol` already uses for each media type, plus
    /// a folder glyph for Browse.
    var symbolName: String {
        switch self {
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .tracks: "music.note"
        case .playlists: "music.note.list"
        case .audiobooks: "book.fill"
        case .podcasts: "antenna.radiowaves.left.and.right"
        case .radios: "dot.radiowaves.left.and.right"
        case .genres: "guitars"
        case .browse: "folder"
        default: "questionmark"
        }
    }

    var searchFilterLabel: String {
        switch self {
        case .artists: String(localized: "media_type_artists")
        case .albums: String(localized: "media_type_albums")
        case .tracks: String(localized: "media_type_tracks")
        case .playlists: String(localized: "media_type_playlists")
        case .audiobooks: String(localized: "media_type_audiobooks")
        case .podcasts: String(localized: "media_type_podcasts")
        case .radios: String(localized: "media_type_radio")
        case .genres: String(localized: "media_type_genres")
        case .browse: String(localized: "nav_browse")
        default: ""
        }
    }
}
