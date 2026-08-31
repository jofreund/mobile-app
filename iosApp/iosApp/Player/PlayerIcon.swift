import SwiftUI

/// A player's icon, drawn from the Music Assistant shared icon set.
///
/// The set (https://github.com/music-assistant/shared-icons) is the canonical
/// artwork for players, devices and areas across every MA client: the server
/// stores one of its ids in `player.icon`, and drawing that id is what makes a
/// Sonos look like a Sonos here, in the web UI and in the Home Assistant card
/// alike. It is vendored rather than depended on — `scripts/sync_shared_icons.py`
/// copies a tagged release into `Assets.xcassets/PlayerIcons` and generates
/// ``PlayerIconCatalog``.
///
/// This replaced a hand-written table that translated the server's old
/// `mdi-*` names into SF Symbols. That table could only ever approximate:
/// there is no SF Symbol for a Sonos, a WiiM, or a Voice PE, so every branded
/// speaker collapsed onto the same generic `hifispeaker` and the picker told
/// you nothing you did not already know. The set draws all three.
struct PlayerIcon: View {

    /// A canonical id from the set — resolve raw server values through
    /// ``resolve(_:isGroup:)`` rather than passing them here directly.
    let id: String

    /// Grows with Dynamic Type like the label beside it, rather than staying
    /// pinned at 24pt while the name around it doubles. The vector
    /// representation the asset catalog keeps is what makes that stay sharp.
    @ScaledMetric private var size: CGFloat

    init(_ id: String, size: CGFloat = 22, relativeTo textStyle: Font.TextStyle = .body) {
        self.id = id
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    var body: some View {
        // Template artwork, so it takes `.secondary`/`.tint` from the context
        // exactly like the SF Symbols it sits next to.
        Image("PlayerIcons/\(id)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// The id to draw for a value the server sent, following the set's own
    /// resolution rules.
    ///
    /// Three kinds of value arrive here. Servers past the icon migration send
    /// a canonical id. Older ones send a Material Design Icons name, which the
    /// set's legacy map translates — that map is a real table of ~200 entries,
    /// not the substring matching the old SF Symbol code had to resort to, so
    /// `mdi-speaker-multiple` and `mdi-speaker` land where they should without
    /// any ordering tricks. Anything else is an id from a *newer* set than the
    /// one vendored here, and there is nothing to draw for it yet.
    ///
    /// Unknowns fall back by kind rather than to the set's single `fallback`,
    /// so a group that names an icon this build has never heard of still looks
    /// like a group.
    static func resolve(_ raw: String?, isGroup: Bool) -> String {
        let fallback = isGroup ? PlayerIconCatalog.groupDefault : PlayerIconCatalog.playerDefault
        guard let name = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return fallback
        }
        if PlayerIconCatalog.ids.contains(name) { return name }
        if let migrated = PlayerIconCatalog.legacyIds[name] { return migrated }
        return fallback
    }
}

#Preview("Every icon") {
    let columns = [GridItem(.adaptive(minimum: 64), spacing: 16)]
    return ScrollView {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(PlayerIconCatalog.ids.sorted(), id: \.self) { id in
                VStack(spacing: 6) {
                    PlayerIcon(id, size: 32)
                    Text(id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
