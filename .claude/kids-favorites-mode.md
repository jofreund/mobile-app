# Kids mode — a favorites carousel for a child's room device

**Date:** 2026-09-04. Status: built on `claude/kids-favorites-carousel-8qrx4q`; not yet run on a
device (this session had no Xcode).

## What it is

A view that replaces the whole app: a Cover Flow of the favorites the signed-in account sees,
a large previous / play-pause / next, a volume slider, and nothing else. Meant for an old phone
or an iPad in a child's room, signed in with the child's own Music Assistant account.

Switched on in Settings ("Kids mode"). Once on, `AppShellRootView` builds `KidsFavoritesView`
instead of `AppTabView`, so no Home fetch, tab bar or mini player exists underneath. A lock glyph
in the top-left corner, held for two seconds, asks an addition question; the right answer opens
Settings (the same full-screen cover as always), where the toggle lives. Guided Access is the
real lock-down; the gate only stops stray taps.

## Why "the favorites of the logged-in user" is the source

Music Assistant stores favorites on library items, shared by every user of a server, and the
maintainers have said per-user libraries will not be built (discussion #5444, June 2026). What
*is* per user: the player filter, the provider filter, and a free-form preferences dictionary
(the web frontend keeps its sidebar shortcuts there, which the Home tab already reads).

So "his favorites" means: sign the room device in as the child. The favorite filter the app
sends is the same one the Library tab offers; the account's player filter, if set, leaves the
app with exactly one player and no selection to make. Nothing new crosses the bridge.

## Where it lives

| Piece | File |
|-------|------|
| The view: carousel, controls, gate, loading | `iosApp/iosApp/Kids/KidsFavoritesView.swift` |
| Pure logic: media types, merge, load outcome, gate question | `iosApp/iosApp/Kids/KidsFavoritesCatalog.swift` (also in the test target) |
| Settings section | `iosApp/iosApp/Settings/KidsModeSection.swift` |
| Preferences (`kids_mode_enabled`, `kids_mode_player_id`, `kids_mode_media_types`) | `iosApp/iosApp/Shell/AppPreferences.swift` |
| Shell switch | `iosApp/iosApp/Shell/AppShellRootView.swift` |
| Tests | `iosApp/iosAppTests/KidsFavoritesCatalogTests.swift`, `AppPreferencesTests.swift` |

## Decisions

- **Data.** One page (50) per enabled media type through `KmpHelper.fetchLibraryItems` with
  `favorite = true`, in the server's default sort; sections concatenated in the configured
  type order, de-duplicated by `provider:itemId`. Default types: albums, playlists,
  audiobooks. Tracks, podcasts and radio are toggles. Artists and genres are out: they open
  pages, and kids mode has none.
- **Nil-vs-empty.** `KidsFavoritesCatalog.outcome` applies the rule from `architecture.md`:
  any timed-out section fails the load; all-empty while not ready for commands fails it too;
  all-empty while ready is a genuinely empty carousel. A failed load keeps what is on screen
  and retries on the not-ready → ready edge, exactly as `HomeView` does.
- **Live changes.** Any `itemChanges` event reloads, so a favorite toggled on the parent's
  phone reaches the room device by itself. Deliberately coarse: three small requests, and
  `.task(id:)` collapses a burst.
- **Player.** The view drives the *selected* player through the store's by-id calls. A
  configured `kidsModePlayerId` is re-applied whenever the player list changes shape or the
  setting does. Selecting by id persists through Kotlin's resolver, which on a dedicated device
  is the right selection to persist. No play-by-player-id bridge call was added: with the
  child's account restricted to the room player the selection is that player by construction.
- **Tapping.** Only the centred card plays (`QueueOption.replace`, no endless mix). Any other
  card scrolls to the centre first.
- **Orientation.** Not forced. `Info.plist` keeps portrait-only on iPhone; the view lays out
  side by side under a compact vertical size class and stacked otherwise. Forcing landscape
  means adding it to the plist and locking every other screen back to portrait through the
  (currently empty) `AppDelegate` — a separate change, if the stand in the room needs it.
- **Cover Flow.** `visualEffect` measured against the scroll view's bounds, not
  `scrollTransition`: the transition phase only knows the distance to the edges, so a mostly
  visible neighbour would sit flat. The rotation sign is tuned by eye; if the near edges
  point outward on a device, flip it in `coverFlowEffect`.
- **Store ownership.** The view owns a `PlayerBarStore`, started in `onAppear` and stopped in
  `onDisappear`; the store has no `deinit`, and this view does go away (kids mode off).

## Not done, and why

- **No deep link / Shortcut entry.** A URL that flips a persisted preference is odd, and the
  room device simply keeps the toggle on. Add `musicassistant://app/kids` if a Shortcut is
  wanted.
- **No orientation lock** (see above).
- **No paging past 50 per type.** A child's favorites fit; the Library tab exists for more.
- **Live Activity** still follows the selected player; on a dedicated device that is the room
  player anyway.

## A playlist as the source (considered, not built)

Asked on 2026-09-04 as an alternative to favorites. Everything needed exists on the bridge:
`fetchPlaylists` for a picker, `fetchTracksByPlaylist` for the cards, and `playFromHere` to
start the playlist at the tapped track. Two facts to keep straight if it is built:

- The web frontend can add an audiobook to a playlist, and it appears as one entry. The
  bridge's `fetchTracksByPlaylist` keeps only `Track` items, so such an entry would be dropped
  on the way to the carousel — that filter would have to widen to `Audiobook` first.
- Audiobooks that live in Apple Music are structured as music albums. Under the favorites
  source they arrive as album cards (albums are on by default) and play as an album, which is
  what is wanted. In a playlist they would only ever be their tracks.

Presentation options, if built: a jukebox (cards are the playlist's entries, a tap plays the
playlist from there) or one card per album derived from the entries. Kept as a second source
next to favorites rather than a replacement, since only favorites can carry whole albums and
audiobooks from every provider.

## Verification

Written without Xcode. Before merging: `xcodebuild test` (the two test files are in the test
target), then on a device: the carousel's rotation sign, the snap on `viewAligned`, whether
`fullScreenCover` fires `onDisappear` on this view (harmless either way), and the gate alert's
number pad.
