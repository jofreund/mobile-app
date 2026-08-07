import SwiftUI
import ComposeApp

// MARK: - Root

/// Native SwiftUI shell for the Phase A spike.
///
/// Presented over the shipping Compose UI rather than replacing it, so the app is
/// already connected and authenticated by the time this appears and the spike
/// never touches the release path. What it is here to demonstrate, none of which
/// Compose-on-iOS can offer: the interactive pop gesture, real scroll physics and
/// rubber-banding, `.searchable`, context menus with an artwork preview, Dynamic
/// Type, SF Symbols, haptics, and the iOS 26 tab bar and glass materials.
struct SpikeRootView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var library = SpikeLibraryStore()
    @State private var search = SpikeSearchStore()

    var body: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                SpikeLibraryView(store: library)
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SpikeSearchView(store: search)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Bottom-leading, level with the floating tab bar: top-trailing collided
        // with the navigation title on pushed screens.
        .overlay(alignment: .bottomLeading) {
            Button("Close spike", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .padding(.leading, 16)
                .padding(.bottom, 14)
        }
    }
}

// MARK: - Library

struct SpikeLibraryView: View {

    let store: SpikeLibraryStore

    @State private var category: SpikeCategory = .albums
    @State private var path: [SpikeMediaItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            SpikeItemCollection(
                state: store.state(for: category),
                layout: category.prefersGrid ? .grid : .list,
                emptyMessage: "Nothing in \(category.title.lowercased()) yet."
            )
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: SpikeMediaItem.self) { item in
                SpikeItemDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Category", selection: $category) {
                            ForEach(SpikeCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbol)
                                    .tag(category)
                            }
                        }
                    } label: {
                        Label("Category", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
            .refreshable { await store.load(category, force: true) }
            .task(id: category) { await store.load(category) }
        }
    }
}

// MARK: - Search

struct SpikeSearchView: View {

    let store: SpikeSearchStore

    @State private var query = ""
    @State private var path: [SpikeMediaItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if case .idle = store.results {
                    // Not `ContentUnavailableView.search`, which says "No Results" —
                    // wrong before anything has been searched for.
                    ContentUnavailableView(
                        "Search your library",
                        systemImage: "magnifyingglass",
                        description: Text("Find artists, albums, and tracks.")
                    )
                } else {
                    SpikeItemCollection(
                        state: store.results,
                        layout: .list,
                        emptyMessage: "No results for “\(query)”."
                    )
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: SpikeMediaItem.self) { item in
                SpikeItemDetailView(item: item)
            }
        }
        .searchable(text: $query, prompt: "Artists, albums, tracks")
        .onChange(of: query) { _, new in
            new.isEmpty ? store.clear() : store.search(new)
        }
    }
}

// MARK: - Detail

struct SpikeItemDetailView: View {

    let item: SpikeMediaItem

    @State private var store = SpikeDetailStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                if item.kind.isBrowsable {
                    SpikeItemCollectionContent(
                        state: store.children,
                        layout: .list,
                        emptyMessage: "Nothing here."
                    )
                }
            }
            .padding(.top, 12)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(for: item) }
    }

    private var header: some View {
        VStack(spacing: 14) {
            SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .fixed(220))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Play", systemImage: "play.fill") {
                    SpikePlayback.play(item)
                }
                .buttonStyle(.glassProminent)

                if item.kotlin.canStartRadio {
                    Button("Radio", systemImage: "dot.radiowaves.left.and.right") {
                        SpikePlayback.startRadio(item)
                    }
                    .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
            .sensoryFeedback(.impact(weight: .medium), trigger: item.id)
        }
    }
}

// MARK: - Shared collection rendering

enum SpikeCollectionLayout { case grid, list }

/// A full-screen collection with its own scroll view, for use as a screen root.
struct SpikeItemCollection: View {

    let state: SpikeLoadState<[SpikeMediaItem]>
    let layout: SpikeCollectionLayout
    let emptyMessage: String

    var body: some View {
        ScrollView {
            SpikeItemCollectionContent(state: state, layout: layout, emptyMessage: emptyMessage)
        }
    }
}

/// The collection body without a scroll view, so a detail screen can embed it
/// inside its own scroll view under a header.
struct SpikeItemCollectionContent: View {

    let state: SpikeLoadState<[SpikeMediaItem]>
    let layout: SpikeCollectionLayout
    let emptyMessage: String

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)]

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)

        case .timedOut:
            // Distinct from "empty" on purpose — see SpikeLoadState.
            ContentUnavailableView(
                "Not connected",
                systemImage: "wifi.exclamationmark",
                description: Text("The server did not respond in time.")
            )
            .padding(.top, 40)

        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView(
                "Nothing here",
                systemImage: "tray",
                description: Text(emptyMessage)
            )
            .padding(.top, 40)

        case .loaded(let items):
            switch layout {
            case .grid:
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { SpikeGridCell(item: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)

            case .list:
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        SpikeListRow(item: item)
                        Divider().padding(.leading, 76)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Cells

private struct SpikeGridCell: View {

    let item: SpikeMediaItem

    var body: some View {
        SpikeItemNavigation(item: item) {
            VStack(alignment: .leading, spacing: 8) {
                SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .flexible(decodeHint: 180))
                    .frame(maxWidth: .infinity)

                VStack(alignment: item.kind.prefersCircularArtwork ? .center : .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: item.kind.prefersCircularArtwork ? .center : .leading)
            }
        }
    }
}

private struct SpikeListRow: View {

    let item: SpikeMediaItem

    var body: some View {
        SpikeItemNavigation(item: item) {
            HStack(spacing: 12) {
                SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .fixed(52))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if item.kind.isBrowsable {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
    }
}

/// Wraps a cell so browsable items push and playable items play, and gives both
/// a context menu with an artwork preview — the long-press interaction Compose
/// cannot produce on iOS.
private struct SpikeItemNavigation<Content: View>: View {

    let item: SpikeMediaItem
    @ViewBuilder let content: () -> Content

    @State private var didFavorite = false

    var body: some View {
        Group {
            if item.kind.isBrowsable {
                NavigationLink(value: item) { content() }
                    .buttonStyle(.plain)
            } else {
                Button { SpikePlayback.play(item) } label: { content() }
                    .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Play now", systemImage: "play.fill") { SpikePlayback.play(item) }
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                SpikePlayback.play(item, option: .next)
            }
            Button("Add to queue", systemImage: "text.badge.plus") {
                SpikePlayback.play(item, option: .add)
            }
            Divider()
            Button(
                item.isFavorite ? "Remove favorite" : "Favorite",
                systemImage: item.isFavorite ? "heart.slash" : "heart"
            ) {
                SpikePlayback.setFavorite(item, !item.isFavorite)
                didFavorite.toggle()
            }
        } preview: {
            VStack(spacing: 10) {
                SpikeArtwork(url: item.artworkURL, kind: item.kind, sizing: .fixed(240))
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .sensoryFeedback(.success, trigger: didFavorite)
    }
}
