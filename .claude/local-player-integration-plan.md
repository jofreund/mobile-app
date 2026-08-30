# Local Player (Sendspin) Integration Plan

**Status:** Implemented (Phases 1–7) — on-device validation (Phase 8) outstanding
**Created:** 2026-08-28 · **Implemented:** 2026-08-30
**Upstream reference:** [music-assistant/mobile-app](https://github.com/music-assistant/mobile-app) @ `ebad772` (2026-08-27)

> Implementation notes vs. this plan: the Kotlin core, `LocalPlayerController`,
> `MainDataSource` wiring, settings (single-store, no secrets split), Swift audio stack
> (`iosApp/iosApp/LocalPlayer/`), Now Playing channels + coordinator, Live Activity
> arbitration (Now Playing wins while the local player presents), and the SwiftUI
> `LocalPlayerSection` all landed. The now-playing channel layer WAS ported after all
> (the plan had marked it Android-oriented) because `NowPlayingCoordinator` needs it.
> Everything Kotlin parses clean under detekt; neither Kotlin/Native compilation nor
> Xcode builds are possible in the CI container (egress policy blocks dl.google.com and
> download.jetbrains.com), so first compile + Phase 8 happen on a Mac.

## Goal

Bring the on-device Sendspin player back into this fork, so the phone itself appears as a
Music Assistant player: audio decoded and played locally, synchronized to the server clock,
controllable from every surface the app already has. This reverses the fork's original
"remote control only" decision and unlocks what the README documents as its cost — **real
lock screen / Control Center integration and background audio**, which iOS grants only to
the app actually producing sound.

## Where things stand

This fork was cut from upstream with the local player deleted, but the deletion was
surgical, not total. That shapes the whole plan: this is a **port back into a diverged
codebase**, not a `git revert` and not a green-field build.

### Still present in this fork (helps us)

- **WebRTC Sendspin plumbing** — `ServiceClient.webrtcSendspinChannel`,
  `WebRTCTransport.sendspinDataChannel`, `WebRTCConnectionManager`'s dedicated channel with
  reconnect/reauth handling (`KtorServiceClient.kt:178-290`). The remote-access transport
  the player will ride on already exists and is exercised in production.
- **`BackgroundUsageGuard`** — written for the OS-level restriction that kills local
  (Sendspin) playback; currently vestigial.
- **`PlayerPositionTracker`** — the single source of truth for elapsed time that upstream's
  `LocalPlayerController` feeds through `PlayerRequestFactory`; the sharing seam is intact.
- **`PlatformContext`** — survived the deletion (see its own header comment) and is what
  `MediaPlayerController`'s constructor needs.
- Comments throughout `MainDataSource`, `KmpHelper`, and `QueueInfo` still describe the
  local-vs-remote routing contract, and `QueueInfoStalenessTest` encodes the optimistic
  queue-timestamp behavior `LocalPlayerController` relies on.
- **`.claude/sendspin-*.md` docs** — describe the upstream implementation accurately; they
  become true of this repo again once the port lands.

### Deleted (what we must bring back)

- The whole `player/` package: `player/sendspin/**` (protocol, audio pipeline, clock sync,
  encryption, identity, pairing), `MediaPlayerController` (expect/actual),
  `MediaPlayerListener`, `PlatformAudioPlayer` bridge.
- `data/LocalPlayerController.kt` (~900 lines: lifecycle + state + command handling) and
  `data/LocalPlayerDispatch.kt` ("play on this device" planning).
- All `sendspin_*` keys and flows in `SettingsRepository`.
- DI registrations (`MediaPlayerController`, `SendspinClientFactory`,
  `LocalPlayerController`, `SendspinKeyStore` in `SharedModule`).
- Swift side entirely: `NativeAudioController.swift` (AudioQueue sink, ~450 lines),
  `AudioDecoders.swift` (libFLAC + swift-opus, ~380 lines), `NowPlayingCoordinator.swift`
  (~530 lines), the SPM dependencies (`sbooth/flac-binary-xcframework`,
  `sbooth/ogg-binary-xcframework`, `alta/swift-opus`), and `UIBackgroundModes: audio`.
- The Local Player section of the native Settings screen (an orphaned doc comment at the
  bottom of `SettingsView.swift` is all that remains).

### Upstream inventory to port (at `ebad772`)

- `commonMain .../player/**`: 44 files, ~7,400 lines. Subpackages: `audio/` (pipeline,
  decoders, adaptive buffering, timestamp ordering), `protocol/` (`MessageDispatcher`),
  `session/`, `transport/` (WebSocket + WebRTC-channel transports), `connection/`,
  `model/`, `noise/` (Noise handshake), `identity/`, `pairing/`, `management/`, plus
  `SendspinClient`, `SendspinClientFactory`, `SendspinConfig`, `SendspinStates`,
  `SendspinError`, `SendspinCapabilities`, `SendspinEncryptionMode`, `StateReporter`,
  `Sync.kt`, `WebRTCChannelGate`.
- `iosMain .../player/`: `MediaPlayerController.ios.kt`, `PlatformAudioPlayer.kt`
  (interface Swift implements + `RemoteCommandHandler` + `PlatformPlayerProvider`
  singleton), `sendspin/audio/` actuals (`OpusDecoder.ios.kt`, `FlacDecoder.ios.kt`,
  `Codec.ios.kt` — thin passthroughs; decoding happens in Swift).
- `commonMain .../data/`: `LocalPlayerController.kt`, `LocalPlayerDispatch.kt`.
- `commonTest .../player/**` + `LocalPlayerDispatchTest`: 28 files — handshake, identity,
  coalescing, factory/WebRTC selection, dispatch planning. All pure-Kotlin, portable.
- **Skip everything `androidMain`** (AudioTrack, Concentus, MediaCodec, services) — this
  fork is iOS-only.

## Key decisions

1. **Port upstream-current, including encryption.** Upstream's Sendspin gained a
   Noise-encrypted protocol, device identity, and pairing since the fork was cut
   (`SendspinEncryptionMode.MIN_SCHEMA_VERSION = 45`, resolved purely by schema version —
   never probed or downgraded). This fork targets schema-59 servers, so the encrypted path
   is the one that will actually run; porting the pre-encryption legacy player would be
   building something already obsolete. The earlier server-communication port (PR #5)
   deliberately skipped "Sendspin encryption" — that debt comes due here.
2. **Keep upstream's package layout byte-for-byte where possible** (`player/sendspin/**`,
   `data/LocalPlayerController.kt`). The protocol core has no UI dependencies, so it should
   drop in nearly clean; keeping paths identical makes future upstream ports diffable.
3. **`MainDataSource` and `SettingsRepository` are merges, not copies.** Both have diverged
   heavily (~1,100 diff lines in `MainDataSource` alone: optimistic playback overrides,
   presentation chapters, favorite overrides, sleep timers). Re-apply upstream's
   local-player wiring *into* the fork's structure, guided by upstream's version.
4. **UI is written fresh in SwiftUI**, exposed through `KmpHelper` like every other
   surface. Upstream's Compose screens (settings section, player badges, pairing dialogs)
   serve as the behavioral spec only.
5. **Now Playing supersedes the Live Activity while local audio is active.** With a real
   audio session, `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` (upstream's
   `NowPlayingCoordinator`) own the lock screen. The fork's existing Live Activity
   (`PlayerActivityController`) stays for the remote-control-only case; exactly one of the
   two drives the lock screen at a time.

## Phases

Each phase compiles, passes `./gradlew :composeApp:testDebugUnitTest` (or the fork's iOS
test task) and builds in Xcode before moving on. Phases 1–3 are pure Kotlin and testable
without a device; 4+ need hardware against a real server.

### Phase 1 — Kotlin protocol core

Copy `commonMain .../player/**` and the iosMain actuals from upstream; add the Koin
registrations (`MediaPlayerController`, `SendspinClientFactory`, `SettingsSendspinKeyStore`)
to this fork's `SharedModule`. Port the `commonTest .../player/**` suite. Swift side not
touched yet — `PlatformPlayerProvider.player` stays null, which the iOS actuals already
tolerate (log-and-drop).

Expected friction: imports referencing upstream models that drifted (e.g. `QueueInfo`,
`Player` fields), Kermit/Ktor version differences, and `SendspinClientFactory`'s
`ServiceClient` surface — verify the fork's `webrtcSendspinChannel` + reconnect API matches
what `WebRTCChannelGate` expects (the fork already carries the channel-reuse/reauth
behavior from upstream #293).

### Phase 2 — Settings & identity

Port the `sendspin_*` block of upstream's `SettingsRepository` (~50 lines): `enabled`
(default **off**), `requireEncryption`, `bgWarningDismissed`, device name, custom-connection
fields, the vestigial `clientId`, plus `SendspinKeyStore`-backed identity persistence
(deliberately plain settings storage, matching upstream — a note in the plan review should
confirm we accept that or move to Keychain). Mirror upstream's proxy-vs-custom-connection
resolution in `SendspinConfig` building.

### Phase 3 — LocalPlayerController & MainDataSource wiring

The delicate phase. Port `LocalPlayerController` + `LocalPlayerDispatch` (+ test), then
re-create in the fork's `MainDataSource` what upstream's does with them:

- Constructor takes `LocalPlayerController`; expose `sendspinState`, `localBufferedSeconds`.
- `localPlayer: StateFlow<PlayerData?>` built from `localPlayerController.localPlayerData`
  merged with the fork's favorite-overrides and presentation-chapter pipelines.
- Merge the local player into `playersData` ahead of server players; the fork's
  `SelectedPlayerResolutionTest` already pins selection semantics — extend it.
- Session-state machine hooks: `start()` on authenticated connect (both Direct and WebRTC
  arms, with the WebRTC sendspin-auth-inheritance special case), `drainCommandQueue()`
  after start, `stop(GoodbyeReason.…)` on the five exit paths upstream distinguishes
  (Shutdown, Restart, UserRequest), `needsServerRefresh → updatePlayersAndQueues()`,
  optimistic queue changes flow.
- Command routing: the local branch of `playerAction(data, action)` goes through
  `LocalPlayerController` instead of `PlayerRequestFactory` — restoring the contract the
  fork's own comments (`KmpHelper.kt:1278`, `MainDataSource.kt:105`) still describe.
  Sleep timers deliberately stay server-side for the local player (`MainDataSource.kt:1155`).
- `applyNowPlayingArtwork` already documents its local-player no-op; make it true.

### Phase 4 — Swift audio stack

- Add SPM packages: `flac-binary-xcframework`, `ogg-binary-xcframework`, `swift-opus`.
  **Risk to retire first** (see Risks): confirm they build under Xcode 26 / iOS 26 target.
- Port `NativeAudioController.swift` (AudioQueue sink, AVAudioSession activation,
  interruption + route-change observers) and `AudioDecoders.swift`.
- Register at startup: `PlatformPlayerProvider.shared.player = NativeAudioController(...)`
  in `iOSApp.swift` (upstream does this at `iOSApp.swift:251`).
- `Info.plist`: add `UIBackgroundModes: audio`.
- Milestone: audio comes out of the phone, screen locked included.

### Phase 5 — Lock screen / Now Playing

Port `NowPlayingCoordinator.swift` (MPNowPlayingInfoCenter metadata + artwork,
MPRemoteCommandCenter → `RemoteCommandHandler` → Kotlin). Reconcile with the Live
Activity: when the selected player is local and the audio session is active, suppress the
Live Activity and let the system Now Playing UI own the lock screen; keep the Live
Activity for remote players. Position updates read from `PlayerPositionTracker` — the same
source the Live Activity uses today, so the two can't disagree.

### Phase 6 — Settings UI (SwiftUI)

Rebuild the Local Player section the orphaned comment in `SettingsView.swift` describes:
enable toggle ("Start/Stop Local Player" semantics live in `MainDataSource`, the toggle
only writes the setting), player name, custom-connection fields, require-encryption
toggle, background-kill warning. All fields lock while the player runs (config is
connect-time). Expose the needed flows/setters through `KmpHelper` following its existing
patterns (`settings-screen.md` States 1–4 and Scenario 5 are the spec).

### Phase 7 — Playback surfaces

- Player picker: show the local player (it now also arrives as a server-side player once
  registered — dedupe by player id, upstream's merge logic is the reference).
- "Play here": wire `LocalPlayerDispatch` (detach-before-play ordering is load-bearing —
  see its header comment) into the surfaces that force playback onto the device.
- Sendspin state/buffer badges in the expanded player, from `sendspinState` /
  `localBufferedSeconds`.

### Phase 8 — Validation

- Full ported unit-test suite green.
- Against a real schema-59 server: Scenario 5 from `settings-screen.md` (toggle, fields
  lock, player appears in MA UI); play/pause/seek/next/prev; codec matrix (PCM, Opus,
  FLAC); encrypted handshake + `requireEncryption` refusal path against an old server if
  one is available.
- iOS-specific: background playback ≥30 min, phone-call interruption resume, headphone /
  AirPlay route change, lock-screen controls, volume via hardware buttons.
- Remote mode: Sendspin over the WebRTC data channel, including a forced WebRTC reconnect
  mid-stream (`KtorServiceClient.forceWebRTCReconnect` path).
- Regression: remote-only flow untouched when the toggle is off — Live Activity still
  works, no audio session is held (App Store review cares about idle audio sessions).

## Risks & open questions

1. **Toolchain fit (check first, Phase 4 risk pulled forward):** the three SPM audio
   packages and AudioQueue code under Xcode 26 beta / iOS 26 minimum. A day-one spike
   building upstream's `iosApp` with this fork's toolchain settles it before any Kotlin
   work is sunk.
2. **`MainDataSource` merge fidelity:** the fork added optimistic playback overrides after
   the fork point; upstream added local-player interplay with *its* optimistic layer.
   Reconciling the two is the likeliest source of subtle bugs (stale-echo suppression —
   `QueueInfoStalenessTest` is the safety net; extend it for local-queue replays).
3. **Live Activity vs Now Playing arbitration:** iOS may render both. Needs an explicit
   owner-election rule (Phase 5) and on-device verification.
4. **Identity/keystore security posture:** upstream stores the Noise identity in plain app
   settings by design. Accept for parity, or move to Keychain as a fork divergence —
   decide at Phase 2, don't improvise mid-port.
5. **Battery/background policy:** `BackgroundUsageGuard` exists but its iOS semantics
   (Low Power Mode, background-app-refresh kills) were never exercised here; revisit in
   Phase 8.
6. **Upstream moves while we port:** pin every ported file to `ebad772`; a follow-up
   upstream-sync PR picks up anything newer, same as the established PR #5/#8/#9 pattern.

## Explicit non-goals

- Android/Android Auto anything (`androidMain` is not ported).
- CarPlay and Siri (out of scope for this fork, per README).
- Compose UI (fork is native SwiftUI).
- mDNS discovery, artwork-over-Sendspin, visualizer (not implemented upstream either).
- Pairing/management UI beyond what silent pairing needs — port
  `SilentPairingCoordinator`; defer any interactive pairing UI until a server flow
  actually demands it.
