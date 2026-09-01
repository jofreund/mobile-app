# Expanded Player Overflow Menu — Implementation Plan

A new overflow (⋯) menu in the top right of the expanded player's header, carrying three
queue-level options: **Autoplay**, **Crossfade** and **Transfer queue**.

**Status: built.** Kept as the design record — the reasoning behind the payload-shaped
feature gate (§7.2), the candidate rules (§3) and the transfer semantics (§4) is not
obvious from the diff. Two things landed differently from the plan and are noted where
they occur: `TransferQueueTargets` filters a `TransferQueueCandidate` protocol rather than
`PlayerBarItemView` (the test target compiles no Kotlin), and the
`ToggleDontStopTheMusic` → `ToggleAutoplay` rename in §7.3.5 was left undone.

Upstream (the Compose client this app was rewritten from) had all of these but crossfade in its
player card's overflow menu. How much of each already exists here differs a lot:

| Option | State | Section |
|---|---|---|
| Transfer queue | Whole Kotlin path exists and is unused — only the Swift entry point is missing | §1–§6 |
| Autoplay | Kotlin path exists but speaks the server's **deprecated** command name; not bridged | §7 |
| Crossfade | Does not exist anywhere in this client — command, model field, action, bridge, UI | §7 |

## 1. What already exists

| Layer | State |
|---|---|
| `APICommands.PLAYER_QUEUES_TRANSFER` | ✅ `player_queues/transfer` |
| `Request.Queue.transfer(sourceId, targetId, autoplay)` | ✅ sends `source_queue_id` / `target_queue_id` / `auto_play` |
| `QueueAction.Transfer(sourceId, targetId, autoplay)` | ✅ `ui/compose/common/action/QueueAction.kt` |
| `MainDataSource.queueAction(...)` | ✅ handles `Transfer`, fire-and-forget like every other queue action |
| `PlayerBarItem.queueId` (`data.queueOrPlayerId`) | ✅ already bridged, per player |
| Strings | ✅ `queue_transfer`, `queue_no_other_players`, `cd_more`, `common_done` — already in `Localizable.xcstrings` in all five locales (they came over from upstream's `strings.xml`) |

Missing: a `KmpHelper` bridge function, a `PlayerBarStore` wrapper, and the SwiftUI menu +
target picker. `KmpHelper.kt`'s own "Player bar" MARK comment already names queue transfer as
one of the deliberately-unreached `PlayerAction`/`QueueAction` cases — this closes that gap and
that comment gets updated.

## 2. UX

**Header menu.** `ExpandedPlayerView.header` is today an `HStack` with the collapse chevron and
a `Spacer`. Add a trailing `Menu` labelled `Image(systemName: "ellipsis")`, accessibility label
`cd_more`, styled like the chevron (`.title3.weight(.semibold)`):

```
⋯  →  [✓] Autoplay                               (queue_autoplay)
      [ ] Crossfade                              (queue_crossfade)  — only when supported
      ──────────────────────────────
      [arrow.left.arrow.right] Transfer queue    (queue_transfer)
```

The two settings are `Toggle`s, which SwiftUI renders inside a `Menu` as a checkmark row: the
current value is visible without opening anything further, and one tap flips it. Transfer sits
under a `Divider` because it is the one entry that opens something rather than changing a
setting. The whole menu is disabled when `player.queueId == nil` — all three act on a queue.

The menu is also the seam the rest of upstream's overflow lands in later (power on/off, clear
queue, DSP settings, playback speed), none of which is in this scope.

**Target picker.** Tapping the entry presents `TransferQueueSheet` — a `.sheet` on the same
`ExpandedPlayerRow`, next to the existing `showPlayerPicker` / `showSleepTimer` sheets, driven
by a new `@State private var showTransferTargets = false`.

A sheet rather than a nested `Menu`, for exactly the reason `PlayerPickerSheet` documents: a
menu row has one image slot and a nested menu inside an overflow menu is two levels of chrome
over a list that can be long. The sheet reuses the picker's row vocabulary — player icon in a
fixed `@ScaledMetric` column, name, `NowPlayingIndicator` for a target that is itself playing —
minus the checkmark, since nothing here is "selected". Title `queue_transfer`, a
`cancellationAction` `common_done` button, `.presentationDetents([.medium, .large])`.

Empty state: `ContentUnavailableView`-style `queue_no_other_players` when no candidate
survives filtering. The menu entry itself stays enabled and opens the sheet to show that
message rather than being silently absent — a disabled row with no explanation is the worse
failure. (Alternative considered: hide the entry entirely. Rejected — it makes a
one-player setup look like the feature does not exist.)

Tapping a row dispatches the transfer and dismisses the sheet. No confirmation dialog: this
matches the immediate-dispatch queue delete already in `ItemMenuContext.removeFromQueue`, and
the action is trivially reversible by transferring back.

## 3. Candidate rules

A player is a valid transfer target when **all** hold:

- `candidate.id != source.id` — never itself.
- `candidate.queueId != nil` — a player with no queue has nothing to receive into.
- `candidate.canPlay` — mirrors what the transport buttons gate on; an announcing or
  non-playable player would swallow the queue.

Deliberately **not** filtered: powered-off players (the server powers a player on when a queue
starts on it — same assumption the player picker already makes by listing them) and group
players (a group is a legitimate destination, and `isGroup` players carry their own queue).

Order: the store's own order, which is the user's configured player sorting
(`MainDataSource.onPlayersSortChanged`). No re-sorting — a list that reorders itself between
the picker and this sheet is disorienting.

This rule set goes in a **pure, testable function** rather than inline in the view, following
`QueueMoveMath.swift`:

```swift
// iosApp/iosApp/Player/TransferQueueTargets.swift
enum TransferQueueTargets {
    static func candidates(from players: [PlayerBarItemView], source: PlayerBarItemView) -> [PlayerBarItemView]
}
```

## 4. Semantics

**`autoplay`** = `source.isPlaying`. Transferring a paused queue should leave it paused on the
target; transferring a playing one should keep the music going, which is the whole point of the
gesture. The server's `auto_play` arg takes exactly this.

**Source id** = `player.queueId ?? player.id`. `queueId` is `queueOrPlayerId` on the Kotlin side
and is nil only when the player has no queue at all — in which case there is nothing to
transfer, so the menu entry is disabled when `player.queueId == nil`.

**After the transfer**, select the target in the player bar
(`store.selectPlayer(id:)`). The queue and the music have moved; the expanded player should
follow them rather than sitting on a now-empty source. This is a deliberate divergence worth
calling out in review — upstream left selection where it was.

**No optimistic state.** The server emits `QueueUpdatedEvent`/`PlayerUpdatedEvent` for both
players and `playerBarState` re-projects; nothing needs patching client-side, same as
`playQueueItem`/`removeQueueItem`.

## 5. Changes, file by file

1. **`composeApp/src/iosMain/.../di/KmpHelper.kt`** — in the `// MARK: - Player queue` section,
   alongside `playQueueItem`/`moveQueueItem`/`removeQueueItem`:

   ```kotlin
   fun transferQueue(sourceQueueId: String, targetQueueId: String, autoplay: Boolean) =
       mainDataSource.queueAction(QueueAction.Transfer(sourceQueueId, targetQueueId, autoplay))
   ```

   Same canonical `queueAction` entry point as its three neighbours — no sibling overload trap
   like the `playerAction` one documented above it. Also update the "Player bar" MARK comment
   and the `ExpandedPlayerView` type doc, both of which currently list queue transfer as
   not-yet-ported.

2. **`iosApp/iosApp/Player/PlayerBarStore.swift`** — thin wrapper:

   ```swift
   func transferQueue(sourceQueueId: String, targetQueueId: String, autoplay: Bool)
   ```

3. **`iosApp/iosApp/Player/TransferQueueTargets.swift`** (new) — the pure candidate filter above.

4. **`iosApp/iosApp/Player/TransferQueueSheet.swift`** (new) — the target list, modelled on
   `PlayerPickerSheet`. Takes `player`, `store`, and an `onTransfer: (PlayerBarItemView) -> Void`
   (or calls the store directly and dismisses — pick one; the store call is fewer moving parts
   and matches how `PlayerPickerSheet` calls `store.selectPlayer`).

5. **`iosApp/iosApp/Player/ExpandedPlayerView.swift`** — `header` gains the `Menu`;
   `ExpandedPlayerRow` gains `@State showTransferTargets` and a `.sheet` presenting
   `TransferQueueSheet`, next to the two existing sheets.

6. **`iosApp/iosApp.xcodeproj/project.pbxproj`** — register the two new Swift files (and the
   test file) in the `iosApp` / `iosAppTests` targets.

7. **`iosApp/iosAppTests/TransferQueueTargetsTests.swift`** (new) — see below.

No Kotlin model, `Request`, or `MainDataSource` change. No new localization keys.

## 6. Tests & verification

- **Unit (`TransferQueueTargetsTests`)**, following `QueueMoveMathTests`: source excluded;
  queue-less player excluded; `canPlay == false` excluded; order preserved; empty result when the
  source is the only player. `PlayerBarItemView` is initialised from a Kotlin `PlayerBarItem`, so
  the test builds fixtures through that initialiser (`PlayerDataFixtures.kt` is the Kotlin-side
  precedent if a helper is wanted).
- **Kotlin**: `./gradlew :androidApp:testDebug` — unchanged, but the shared framework must still
  build for iOS after the `KmpHelper` addition.
- **Manual**, against a real server with ≥2 players: transfer a *playing* queue → music
  continues on the target, source stops, expanded player follows to the target; transfer a
  *paused* queue → target holds the queue paused; single-player setup → sheet shows
  `queue_no_other_players`; a player with no queue → the ⋯ entry is disabled.

## 7. Autoplay and Crossfade

### 7.1 What the server actually calls these

Verified against `music-assistant/server` `music_assistant/controllers/player_queues/controller.py`
and `music-assistant/models` `player_queue.py` (both `main`), not from memory:

| Command | Args |
|---|---|
| `player_queues/autoplay` | `queue_id`, `autoplay_enabled` |
| `player_queues/dont_stop_the_music` | `queue_id`, `dont_stop_the_music_enabled` — declared `alias=True`, i.e. the deprecated spelling of the one above |
| `player_queues/crossfade` | `queue_id`, `crossfade_enabled` |

The `PlayerQueue` payload carries `autoplay_enabled` and `crossfade_enabled`. For old clients its
serializer still mirrors `d["dont_stop_the_music_enabled"] = d["autoplay_enabled"]`, and its
deserializer still accepts the old key — which is why this client works today while reading and
writing only the deprecated name.

So: **"Don't Stop The Music" and "Autoplay" are the same setting**, renamed server-side. This
client is on the old name end to end (`ServerQueue.dontStopTheMusicEnabled` →
`QueueInfo.autoPlayEnabled`, `PlayerAction.ToggleDontStopTheMusic`,
`Request.Queue.setDontStopTheMusic`) — which explains the two parallel string families in the
catalog (`queue_autoplay_*` and `queue_dsm_*`) that upstream carried. Crossfade has no
counterpart here at all.

### 7.2 Feature detection: the payload, not a schema constant

`SleepTimerSupport.kt` gates on `schemaVersion >= 35`. That pattern is wrong for these two,
because it means pinning the exact schema at which the rename and the crossfade field landed —
archaeology this plan would rather not bet on. `ServerQueue` already documents the better tool:
`playback_speed` is nullable *on purpose*, so `null` means "this server doesn't do that".

Same rule here:

- `ServerQueue.autoplayEnabled` (new key, nullable) alongside the existing legacy key.
  `QueueInfo.autoPlayEnabled = autoplayEnabled ?: dontStopTheMusicEnabled`.
- `QueueInfo.supportsAutoplayCommand = autoplayEnabled != null` — a server that *sends*
  `autoplay_enabled` understands `player_queues/autoplay`; one that doesn't gets the alias.
  Nothing is guessed and nothing needs updating when the alias is eventually dropped.
- `QueueInfo.crossfadeEnabled: Boolean?` — `null` means the server never sent
  `crossfade_enabled`, and the Crossfade row is hidden. Any other value shows the toggle.

### 7.3 Kotlin changes

1. **`APICommands.kt`** — `PLAYER_QUEUES_AUTOPLAY = "player_queues/autoplay"`,
   `PLAYER_QUEUES_CROSSFADE = "player_queues/crossfade"`. Keep
   `PLAYER_QUEUES_DONT_STOP_THE_MUSIC`; it is still the fallback.
2. **`Request.kt`** — `Queue.setAutoplay(queueId, enabled)` (new command) next to the existing
   `setDontStopTheMusic`, and `Queue.setCrossfade(queueId, enabled)`.
3. **`ServerQueue.kt`** — `@SerialName("autoplay_enabled") val autoplayEnabled: Boolean? = null`
   and `@SerialName("crossfade_enabled") val crossfadeEnabled: Boolean? = null`, both defaulted
   per the file's decode-tolerance contract. Replace the stale
   `// TODO replace with "auto_play" when available` comment with what the two keys now mean —
   the real name turned out to be `autoplay_enabled`, not `auto_play`.
4. **`QueueInfo.kt` / `QueueFactory.kt`** — map both, derive `supportsAutoplayCommand`.
5. **`PlayerAction.kt`** — add `ToggleCrossfade(val current: Boolean)`. Rename
   `ToggleDontStopTheMusic` → `ToggleAutoplay` to match the server and the UI label; it is a
   client-internal name, so this is mechanical (4 call sites: `PlayerRequestFactory`,
   `LocalPlayerController` ×2, `PlayerAction` itself). **Own commit**, no behaviour change.
6. **`PlayerRequestFactory.kt`** — the autoplay branch picks
   `setAutoplay` vs `setDontStopTheMusic` off `queueInfo.supportsAutoplayCommand`; a new
   crossfade branch mirrors the shuffle branch (`queueId ?: return null`, invert `current`).
7. **`LocalPlayerController.kt`** — the built-in player's queue lives server-side, so both
   toggles go out as normal requests; what it needs is the two local pieces the other toggles
   have: an optimistic `updateOptimisticQueueInfo { it.copy(crossfadeEnabled = ...) }` branch,
   and a coalescing branch in the offline command queue. Coalescing must copy the
   **cancel-on-second-tap** shape used by shuffle/DSM (`indexOfFirst` → remove, else add), not
   the replace shape used by repeat/seek: two taps of a boolean toggle are a no-op and should
   leave nothing queued. Without an explicit branch these fall into `else -> commandQueue.add`,
   which would send both taps.
8. **`PlayerBarState.kt`** — `PlayerBarItem` gains `autoplayEnabled: Boolean`,
   `crossfadeEnabled: Boolean`, `crossfadeSupported: Boolean`. Two flat booleans rather than one
   `Boolean?`, following the file's own rule (`GroupMemberBarItem.canMute` flattens a nullable
   the same way) so Swift never sees a `KotlinBoolean?`. Projected in `buildPlayerBarState`.
   Note `playerBarStatesEquivalentIgnoringElapsed` needs no change — it compares whole data
   classes by design.
9. **`KmpHelper.kt`** — `togglePlayerBarAutoplay(playerId:isEnabledNow:)` and
   `togglePlayerBarCrossfade(playerId:isEnabledNow:)`, both through `dispatchPlayerBarAction`
   (the `PlayerData`-based overload — the string-id overload's `when` is the incomplete one the
   file's comment warns about, and would silently drop these).

### 7.4 Swift changes

- `PlayerBarItemView` mirrors the three new fields.
- The two `Toggle` rows in the header menu, bound through
  `Binding(get: { player.autoplayEnabled }, set: { _ in store.toggleAutoplay(id:isEnabledNow:) })`
  — the same "pass the current value, Kotlin computes the next one" shape the shuffle, repeat
  and mute bridges already use. No local optimistic state: the server echoes
  `QueueUpdatedEvent` and `playerBarState` re-projects, exactly as it does for shuffle today.
- `PlayerBarStore` gains the two thin wrappers.
- The Crossfade row is wrapped in `if player.crossfadeSupported`.

### 7.5 Strings

`queue_transfer`, `queue_no_other_players`, `cd_more` and `common_done` are already in the
catalog. The two toggles need **noun** labels, which upstream never had — its entries were verb
phrases for a menu that showed one action at a time (`queue_autoplay_enable` / `_disable`,
`queue_dsm_enable` / `_disable`). A toggle that already shows its state reading "Enable
Autoplay" while switched on is wrong, so add two `"extractionState": "manual"` keys (the
convention the catalog documents for hand-added strings):

| Key | en | de | nl | sr | zh-Hans |
|---|---|---|---|---|---|
| `queue_autoplay` | Autoplay | Autoplay | Autoplay | Аутоматска репродукција | 自动播放 |
| `queue_crossfade` | Crossfade | Überblenden | Crossfade | Прелаз | 淡入淡出 |

The `sr` and `zh-Hans` values are proposals and should be reviewed by someone who reads them;
`de`/`nl` follow the wording already used in `queue_autoplay_enable`. The four upstream verb
keys stay in the catalog unused — it already holds unused upstream keys, and they cost nothing.

Label choice: **"Autoplay"**, the server's current name, not "Don't Stop The Music". A server
old enough to only know the alias still shows the new label; showing the old name on old servers
would mean branching a label on a feature-detect flag, which is more machinery than the
inconsistency is worth.

### 7.6 Tests

- `ServerQueueSerializationTest` — `autoplay_enabled` decodes; only `dont_stop_the_music_enabled`
  present still yields the same `QueueInfo.autoPlayEnabled` (and `supportsAutoplayCommand ==
  false`); neither present leaves crossfade `null`.
- `PlayerRequestFactoryTest` — crossfade toggle inverts the current value and targets the queue
  id; autoplay emits `player_queues/autoplay` when supported and
  `player_queues/dont_stop_the_music` when not; both return `null` with no queue.
- `PlayerBarStateTest` — the three new flags project, including `crossfadeSupported == false`
  for a `null` field.
- `LocalPlayerDispatchTest` — two crossfade taps queued offline cancel out rather than both
  being sent.
- Manual: toggle each on a real server and watch the web frontend's own queue settings follow;
  toggle from the frontend and watch the menu follow; point the app at an older server image
  (`scripts/run-local-ma.sh` with a pinned tag) and confirm the Crossfade row is absent while
  Autoplay still works through the alias.

## 8. Out of scope

The rest of upstream's overflow menu — power on/off (`player_power_off`/`player_power_on`),
clear queue (`queue_clear`), DSP settings (`players_dsp_settings`), playback speed, lyrics,
go-to-artist/album. Their strings and Kotlin actions are all present; this plan only builds the
menu they will hang from. Also out of scope: the newer queue features this client models not at
all — `overlay_*`, `smart_fades_active`, `smart_shuffle_active`.

## 9. Open questions

1. **Transfer semantics.** `auto_play = source.isPlaying` and "follow the selection to the
   target" are judgement calls made here, not copied from upstream. Matching upstream exactly
   (no auto-follow, `auto_play` left to the server's own default) is a one-line change either
   way, but it changes how the feature feels.
2. **The `ToggleDontStopTheMusic` → `ToggleAutoplay` rename** (§7.3.5) is optional. It buys one
   vocabulary across client, server and UI label; it costs a mechanical diff through
   `LocalPlayerController`, which is the most delicate file the change touches.
3. **`sr` and `zh-Hans` translations** for the two new keys (§7.5) need a reviewer.
