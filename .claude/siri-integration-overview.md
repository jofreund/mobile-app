# Upstream Siri Integration — Overview

**Researched:** 2026-09-01, against upstream `music-assistant/mobile-app` @ `c9166f8`.

What upstream's Siri integration enables, how it is built, and what a port back into this
fork would need. This fork removed the integration entirely (README: "Siri / Assistant:
Both | Neither"); the detailed design doc `.claude/carplay.md` was retained from upstream
and is still byte-identical to upstream's copy (last reviewed 2026-04-28). This overview
summarizes it, verifies it against upstream's current source, and records where the code
has drifted past the doc.

---

## Status in this fork

Removed, with deliberate remnants:

- `iOSApp.swift` — `AppDelegate` is empty; comments note the SiriKit `handlerFor` and the
  CarPlay scene branch "went with those integrations". `KmpState.isReady` survives: it
  existed so intent handlers running before any scene connected could bail instead of
  dereferencing an uninitialized Koin graph.
- `KmpHelper.kt` — `setFavorite(item, favorite)` survives (now serving the long-press
  context menu) and its doc comments still describe the Siri contract: synchronous
  `Boolean` = "request could be formed", used so Swift doesn't lie to Siri about success.
- `.claude/carplay.md` — upstream's full design doc, kept as reference.

## What it enables (user perspective)

Upstream registers the app with Siri as a **media destination** via three SiriKit
media-domain intents, hands-free and CarPlay-compatible:

| Phrase | Intent | Behavior |
|---|---|---|
| "Hey Siri, play X in Music Assistant" | `INPlayMediaIntent` | Search MA → best match (track/album/artist/playlist/audiobook/radio/podcast/genre) → play → donate |
| "I love this song" / "I don't like this" | `INUpdateMediaAffinityIntent` | Like ⇒ add MA favorite, dislike ⇒ remove (MA has no negative signal) |
| "Search for X in Music Assistant" | `INSearchForMediaIntent` | Surface results without playing; follow-up "play that" routes through `INPlayMediaIntent` |

Donations from successful plays teach Siri's prediction model, so plain "play X" (without
the app name) can eventually resolve to MA.

**Transport commands are not part of this.** "Skip", "pause", "next", and steering-wheel
buttons flow through `MPRemoteCommand` (dispatched by `mediaremoted`) into
`NowPlayingManager`/`NativeAudioController` — never through the intent handler. The two
paths share no code; when triaging "Siri did the wrong thing", classify by what was said
(content phrase vs. transport phrase) before reading any code.

## How it is built (upstream)

**Registration — all declarative.** `Info.plist`:

- `INIntentsSupported` — the three intent class names; enables **handling**.
- `INSupportedMediaCategories` — Music, Audiobooks, Podcasts, Radio. Missing ⇒ "Sorry,
  Music Assistant hasn't added support for that with Siri".
- `NSUserActivityTypes` — same three class names; enables **donating**. Missing ⇒
  `IntentsErrorDomain Code=1901` on donate while handling still works (easy to miss).
- `NSSiriUsageDescription`, plus `com.apple.developer.siri` in the app entitlements and
  the SiriKit capability (media types) in Signing & Capabilities.

**Routing — in-app, no Intents extension.** `AppDelegate.application(_:handlerFor:)`
returns one `SiriIntentHandler` for all three intent classes. Handlers can fire before any
scene connects, so `iOSApp.init()` runs `bootstrapKmp()` up front and handlers bail with
`.unsupported` / `.failureRequiringAppLaunch` when `KmpState.isReady` is false.

**The handler** (`iosApp/iosApp/CarPlay/SiriIntentHandler.swift`, ~760 lines; one class,
three protocol conformances as extensions, shared machinery):

- *Query extraction* — prefer the voice transcript (`mediaSearch.mediaName`, concatenated
  with `artistName` when present); fall back to `mediaItems[0].title + artist` when Siri
  pre-resolved against its own Apple Music catalog. Those identifiers are Apple's, not
  MA's, so the app always re-searches MA and returns its own items.
- *Search* — `KmpHelper.search(query:)`: MA `Library.search`, 6 media types, `limit=10`,
  `libraryOnly=false`.
- *Matching* (`bestMatch(in:for:query:)`) — drop non-mappable items (RecommendationFolder);
  type-filter by Siri's `INMediaItemType` with fallback to all (Siri usually sends
  `.unknown` for non-Apple-Music apps); score by token overlap between query and
  name ∪ subtitle (lowercased, diacritic/width-folded, apostrophes/punctuation stripped —
  "Beyonce" matches "Beyoncé"); tiebreak by MA's original order. Scoring exists because
  MA's server relevance can rank an unrelated artist above the intended same-named album.
- *Disambiguation policy* — `INPlayMediaIntent.resolveMediaItems` **never** returns
  `.disambiguation`: each user tap comes back as a fresh intent whose Apple identifiers
  don't match MA's, so any non-`.success` restarts the cycle — an infinite loop. Always one
  best match or `.unsupported`. The affinity intent *does* disambiguate (capped at 5): a
  one-shot mutation whose pre-filled follow-up intent early-returns `.success`.
- *Cache* — static `NSCache<NSString, AppMediaItem>` (100 items) keyed by MA item id
  bridges resolve → handle (Siri may recreate the handler between phases) and lets
  follow-up intents resolve "this song" without a server round-trip.
- *Affinity nuance* — the handler prefers a `mediaSearch.mediaName`-driven re-search over
  the cache-hit shortcut, because Siri's disambig may have led the user to tap a
  wrong-type catalog candidate (the artist when "I love this song" meant the track).

**Donations.** After every successful play — Siri-initiated and every user-initiated
CarPlay play — the app donates an `INPlayMediaIntent` with identifier
`play-<serverId>-<itemId>` (`serverId` from the MA handshake namespaces the
server-relative item id: re-plays consolidate, servers don't collide). Failure paths skip
donation and report `.failure` so phantom plays don't pollute the prediction model.
In-app (Compose) plays deliberately don't donate: that would require distinguishing
user-initiated plays from queue auto-advance, which must not donate.

**Kotlin bridge** (`composeApp/src/iosMain/.../di/KmpHelper.kt`): `search`,
`setFavorite` (add by `referenceUri` / remove by id+mediaType; synchronous `Boolean` =
"request could be formed", surfaced to Siri as success/failure — network outcome is
fire-and-forget), `getServerId`, and the play dispatch. Completions fire on the main
thread.

## Drift: current upstream code vs. `.claude/carplay.md`

The doc (2026-04-28) is accurate except:

- **Play dispatch targets the local player.** The doc says `KmpHelper.playMediaItem`
  (selected player + `QueueOption.PLAY`); current code calls
  `playOnLocalPlayer(item:option:)` — the on-device Sendspin player — returning `false`
  (no donation, Siri failure tone) when there is no local player or the item has no URI.
  Siri "play X" now plays *on the phone*, not on whichever MA player is selected.
- **More donation call sites.** `CarPlayContentManager` donates from `play`,
  `playWithDefault` (per-kind configured tap action), and `playBulkAction`, on any
  user-initiated dispatch (immediate or queued) — "intent to play is what matters, not
  whether the RPC landed".
- `setFavorite` now addresses adds by `referenceUri` (always present), so both affinity
  directions are always expressible; the doc's "no URI ⇒ false" caveat is stale.

## Known limits (upstream's own assessment)

- Affinity applies the favorite server-side, but Siri's confirmation UI can show
  "something went wrong" (`SiriAudioAffinityScorer` can't ground the item). Upstream's
  dispositive fix is **Core Spotlight indexing** of the MA library (TODO, alongside
  `INMediaUserContext`, `AppIntentVocabulary.plist`, `INVocabulary`).
- `INSearchForMediaIntent` and the in-car flows were untested as of the doc's review.

## Porting checklist for this fork

1. `Info.plist`: `INIntentsSupported`, `INSupportedMediaCategories`,
   `NSUserActivityTypes`, `NSSiriUsageDescription`; `com.apple.developer.siri`
   entitlement; SiriKit capability in Signing & Capabilities.
2. `SiriIntentHandler.swift` — portable nearly verbatim; it depends only on the KMP bridge
   and `KmpState.isReady`. Decide what "play" means here: this fork's local player is
   optional and off by default, so upstream's `playOnLocalPlayer` is the wrong default —
   dispatch to the selected player (the doc's original `playMediaItem` semantics), or
   branch on the local-player toggle.
3. `AppDelegate` (`iOSApp.swift`) — restore `application(_:handlerFor:)`. `KmpState.isReady`
   is already there waiting.
4. `KmpHelper.kt` — `setFavorite` survives; `getServerId` and a Siri-shaped `search` need
   restoring (the fork's `searchDetailed` is close but returns type-bucketed results at
   limit 200; the handler wants a flat list at limit 10).
5. Donations: without CarPlay, the only donation source would be Siri's own successful
   plays — enough to keep the model alive once the user starts using it, but consider
   donating from user-initiated in-app plays (not queue auto-advance) to bootstrap it.
