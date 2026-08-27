# Using the app

A tour of the native iOS client. Text only, deliberately: this replaced a screenshot-heavy manual
of the Compose UI, and stale screenshots of an interface that no longer exists mislead harder than
no screenshots at all.

Everything here controls **remote players** on your Music Assistant server. The app plays no audio
itself, which is why it has no lock screen or Control Center presence — see the README for why
that can't be added back without local playback.

## First run

The app opens on Settings when there's nothing to connect to.

**Direct** is the normal path: host and port, prefilled with `homeassistant.local` and `8095`. iOS
asks for local-network permission before the first attempt rather than failing once and then
asking. **WebRTC** connects by remote ID, typed or scanned as a QR code, for reaching a server
that isn't on your network.

Once connected, sign in with Music Assistant credentials or via Home Assistant OAuth, which opens
the system browser. Saved connections are kept, so switching between servers doesn't mean retyping.

## Home

Recommendation rows from your server, plus shortcuts, as horizontal carousels.

The **pencil** in the toolbar opens edit mode: drag rows to reorder them, toggle them off, done.
The arrangement is stored server-side alongside everything else.

Pull down to refresh — including on an empty state, which is where you're most likely to want it.

## Library

A table of categories: Artists, Albums, Tracks, Playlists, Podcasts, Audiobooks, Radio, Genres,
Browse. The same pencil reorders and hides them.

Inside a category:

- **Search** filters within it.
- **Sort** by name, date added and so on, where the server supports it.
- **Filter** by favourites, provider, or genre.
- **List or grid**, toggled per category and remembered.
- **Playlists** additionally offer creation.

Lists page as you scroll. **Browse** walks your providers' own folder trees instead of the
library index.

## Search

Spans artists, albums, tracks, playlists, podcasts, audiobooks and radio. Results arrive on submit
rather than per keystroke — a search is a server round trip, not a local filter.

When several types match, a row of chips over the results narrows them to one type — that's a view
over what already arrived, so it applies instantly without asking the server again. The filter
button in the toolbar restricts the search itself to your library, which does re-run it.

## Playing something

Tap any playable item to play it now. **Long-press** anything for the full set: play next, add to
queue, start radio, favourite, add to or remove from a playlist, mark played or unplayed, add to
or remove from library. Which of those appear depends on the item and where you are — a track
inside an album offers "play album from here", the same track in search results doesn't.

## The player

A **mini player** sits above the tab bar showing what's playing. Swipe it sideways to move between
players; long-press it to pick one from a list. Tap it to expand.

The **expanded player** has artwork, a seek bar, shuffle, previous, play/pause, next, and repeat,
plus a volume slider. Swipe sideways here too, or tap the player name for the same picker. Swipe
down to dismiss.

While an **audiobook** is playing the seek bar spans the current chapter rather than the whole
book, the timestamps read chapter-relative, and the chapter name replaces the artist/album line.
Previous and next then step by chapter — for podcast episodes with chapter metadata too — with
Previous restarting the current chapter unless you press it within five seconds of its start.
This follows the server's `audiobook_chapter_progress` setting, which is toggled in the Music
Assistant web interface: with it off, everything stays on whole-book time and the transport
buttons move between queue items.

Two things live in the expanded player's header:

- **Queue** — the upcoming list. Tap to jump, drag to reorder, long-press for the item menu
  including remove. Audiobook chapters nest under the current item and can be tapped to seek.
  Dropping an item at or before the currently-playing one is rejected, as it is server-side.
- **Group settings** — appears when the player is grouped or could be. Add and remove members,
  set each member's volume, and set the group volume. Some members are fixed by the server and
  can't be removed; those controls are disabled rather than hidden.

## Settings

Reachable from the gear in Home's toolbar; it opens over the app and closes with ✕.

Server info and disconnect, the signed-in account and logout, appearance (Dark / Light / Follow
System), and log sharing — **Share logs** writes a file you can send on, which is the fastest way
to diagnose anything the UI reports vaguely.
