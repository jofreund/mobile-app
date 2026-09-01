# Transfer Queue — Implementation Plan

Port upstream's **"Transfer queue"** action to the native iOS player, reached from a new
overflow (⋯) menu in the top right of the expanded player's header.

Upstream (the Compose client this app was rewritten from) exposed it in the player card's
overflow menu: pick another player, the queue moves there and keeps playing. Everything below
the bridge boundary for that already exists here — only the Swift entry point is missing.

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
`cd_more`, styled like the chevron (`.title3.weight(.semibold)`). One entry for now:

```
⋯  →  [ arrow.left.arrow.right ]  Transfer queue      (queue_transfer)
```

The menu is the seam upstream's other overflow entries land in later (power on/off, Don't Stop
The Music, clear queue, DSP settings, playback speed — all of which already have strings and
Kotlin actions, none of which are in this scope).

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

## 7. Out of scope

The rest of upstream's overflow menu — power on/off (`player_power_off`/`player_power_on`),
Don't Stop The Music (`queue_dsm_*`), clear queue (`queue_clear`), DSP settings
(`players_dsp_settings`), playback speed, lyrics, go-to-artist/album. Their strings and Kotlin
actions are all present; this plan only builds the menu they will hang from.

## 8. Open question

`autoplay = source.isPlaying` and "follow the selection to the target" are both judgement calls
made here rather than copied from upstream. If either should instead match upstream exactly
(no auto-follow; `auto_play` left to the server default), say so before implementation — both
are one-line changes but they change how the feature feels.
