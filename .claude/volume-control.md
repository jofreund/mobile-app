# Volume Control

**Last reviewed:** 2026-04-28

## Design intent (mobile)

The mobile app does **not** attempt bidirectional system-volume sync between the device and the Music Assistant server. We rely on the OS-native audio paths instead:

- The user's hardware volume buttons control the device's system audio output directly (OS-level), as on any other audio app.
- The server can push a volume value to the player at the audio-path layer (app-level mixer gain), and the app applies it.
- These two paths are orthogonal; final output ≈ OS gain × app gain.

Rationale: continuous device→server volume reporting on mobile (especially with hardware-button changes) introduces debounce/echo bugs that aren't worth solving for a phone-as-player experience where users expect the hardware buttons to "just work" against the OS.

## Built-in player (this device acting as a Music Assistant player)

| Path | Implementation |
|---|---|
| Server → device gain | Server sends `{"type":"server/command","payload":{"player":{"command":"volume","volume":<0-100>}}}` → `SendspinClient.handleServerCommand()` calls `mediaPlayerController.setVolume(n)` |
| Android audio-path gain | `MediaPlayerController.android.kt` `setVolume()` → `AudioTrack.setVolume(n/100f)` |
| iOS audio-path gain | `MediaPlayerController.ios.kt` `setVolume()` → `NativeAudioController.setVolume()` → `AudioQueueSetParameter(queue, kAudioQueueParam_Volume, n/100)` |
| Server → device mute | Same protocol (`"command":"mute","mute":<bool>`); each platform applies via the same audio-path API (mute = gain 0) |
| Device → server | **Not wired.** No platform observes hardware-volume changes; nothing gets reported back. |
| In-app volume slider | **None, by design.** Hardware buttons are the user-facing control. |

There is also a `MediaPlayerController.getCurrentSystemVolume(): Int` `expect` declaration. It is currently called once at construction and once on each `connectWithTransport()` in `SendspinClient`, but the value is only used for a startup log line — it does not flow into the protocol or into any reader. (Flagged as candidate for a future dead-code cleanup pass; not a behavioural concern.)

## Other players (this device controlling a different player on the network)

The MA player model exposes `canSetVolume`, `volumeLevel`, `groupVolume`, etc. on each `Player`. The mobile app **does** show an in-app slider for those:

- `PlayersPager.kt:344-391` — pager-card slider on the Now Playing carousel
- `SelectPlayerDialog.kt:509-544` — slider in the player-picker dialog

Visibility gate: `Player.isVolumeSliderAccessible = (isGroup || canSetVolume) && currentVolume != null`. When the slider moves, the app sends `PlayerAction.VolumeSet(value)` (or `GroupVolumeSet(value)` for groups) over the main MA connection — that path is unrelated to the Sendspin built-in-player path described above.

## Platform parity

Both platforms behave the same way today:

| Path | Android | iOS |
|---|---|---|
| Server-pushed volume → audio output | ✅ via `AudioTrack.setVolume` | ✅ via `AudioQueueSetParameter` |
| Hardware buttons → OS system volume | ✅ (handled by OS) | ✅ (handled by OS) |
| Hardware buttons → server reporting | ❌ not wired | ❌ not wired |
| `getCurrentSystemVolume()` returns real value | ✅ reads `AudioManager.STREAM_MUSIC` | ⚠️ stubbed to `100` (inconsequential — only feeds a log line) |
| In-app slider for built-in player | ❌ by design | ❌ by design |
| In-app slider for other players on network | ✅ | ✅ (confirmed working on TestFlight 2026-04-28) |

Effectively at parity. The iOS `getCurrentSystemVolume()` stub is a cosmetic gap, not a functional one.

## Attempted 2026-08-31: in-app slider for the built-in player (reverted)

Someone asked why the local player has no volume slider, and the attempt to add one was
reverted the same day. Recording it so the next person doesn't repeat it.

**What was tried, in order:**

1. **Declare the volume/mute capability.** `SendspinCapabilities.buildClientHello()` sends
   `supported_commands: []`, so the server never learns the client can take a `volume`
   command. Declaring `[VOLUME, MUTE]` was expected to make MA expose `volume_set` for the
   player, which is what `Player.isVolumeSliderAccessible` gates on. Note `LegacyWireGoldenTest`
   pins the client/hello wire shape, so changing this requires updating that golden.
2. **Route volume through the server anyway.** With the slider forced visible, dragging it
   produced `players/cmd/volume_set` → **`error_code 9`, "not supported"**. The MA server
   refuses volume control for this player. Whether a server restart or provider reload would
   change that after (1) was never tested.
3. **Make volume client-owned.** Intercept the four volume actions in
   `LocalPlayerController.handleLocalCommand` before a request is built, apply them straight
   to the sink, persist the level in settings, and re-stamp the fields in
   `onServerPlayerUpdate` (which replaces the local player wholesale from the server payload,
   and would otherwise drop the slider mid-playback). This worked, and was still reverted.

**Why it was dropped:** an in-app slider and the hardware buttons are two independent controls
over the same output — the app's gain and the OS's — and having both is worse than having one.
That is the same conclusion the "Design intent" section above already reaches; the attempt
simply rediscovered it the long way. For reference, iOS gives no sanctioned API to set the
system volume (`AVAudioSession.outputVolume` is read-only, `MPVolumeView` is a user-driven
control), so a slider that moves the *device* volume rather than an app-level gain is not
available to us anyway.

**Two real defects found along the way, both still present** (they need a volume command from
the server to manifest, which is the only volume path that exists today):

- `NativeAudioController.setMuted()` writes `kAudioQueueParam_Volume`, the *same* parameter as
  `setVolume()`. Unmuting snaps output to `1.0`, so muting at 30% and unmuting jumps to full.
- Neither setter stores the level, and `setupAudioQueue()` never applies one. The queue is torn
  down and rebuilt on format change, so a server-set volume silently resets to full on the next
  track at a different sample rate. Both setters also drop the value entirely when no queue
  exists yet.

Fixing both is small — hold `gain`/`muted` on the controller, have one writer apply
`muted ? 0 : gain`, and re-apply it after `AudioQueueNewOutput` succeeds.

**Also confirmed:** `PlayerStateObject` (`sendspin/model/Messages.kt`) carries only `state` —
there is no volume or mute field on the wire, despite `StateReporter`'s docstring claiming it
reports them. So `SendspinClient.currentVolume`/`currentMuted` are tracked and sent nowhere,
and the device→server row in the table above cannot be wired without a protocol change. This
also means the `getCurrentSystemVolume()` stub noted above is even less consequential than
described: nothing downstream reads it at all.

## Historical note

A previous version of this document described a `MediaSessionHelper` + `ContentObserver` design for Android with continuous bidirectional sync. That code is not present in the current Sendspin-based codebase — it appears to have described an earlier ExoPlayer-era integration that was replaced. The bidirectional-sync intent was deliberately not carried forward.
