# Intercom tab — plan

**Status:** decided, being built. Written 2026-10-09.

Upstream added spoken and typed announcements in `4bbab882` ("Play announcement (typed or
spoken)", #1101): an entry in the expanded player's overflow menu opens a Compose dialog with a
*Type* and a *Speak* tab. This fork gets the feature as its own tab instead, built from
`jofreund/ios-home-intercom` — the push-to-talk grid, its pop-over, waveform, haptics and card
state machine — with Music Assistant players in place of Home Assistant rooms.

## What upstream built

- **Typed:** `players/cmd/play_announcement` with `message`; the server speaks it through a
  TTS engine. Offered when the schema is ≥ 46 *and* `players/tts_engines` is non-empty.
- **Spoken:** there is no upload endpoint. The client opens a socket to `/live_announcement`
  (direct) or a `live_announcement` data channel (WebRTC) and runs a small protocol:
  `auth` → `start` (player, sample rate, channels, optional `pre_announce`/`volume_level`) →
  server `started` → binary frames of raw s16le PCM → any text frame (`stop`) → server
  `finished` or `error` **after the clip has played**. Offered at schema ≥ 48, never for the
  phone's own player.
- Kernel: `AnnouncementRepository` (availability, chime setting, `type`, `speak`),
  `runLiveAnnouncement` (the protocol over an `AnnouncementLink`), `MicrophoneCapture` with an
  `AVAudioEngine` tap on iOS (`AudioEngineCapture.kt`), `openDataChannel(label)` on the WebRTC
  manager. Both kinds run in an app scope, because the server answers only after playback.

## The protocol fact that shapes the design

`music_assistant/controllers/streams/live_announcements.py` has no way to discard a clip. A
text frame ends it, a closed connection ends it, ten seconds without a frame end it — and in
every case whatever audio arrived is played ("a client that drops still gets what it spoke
played out"). Only a clip with **zero** audio is dropped silently.

Upstream streams frames as they are captured, so once the user has said a word the message
*will* play. home-intercom's flow depends on the opposite: slide off the card and nothing is
sent, let go too early and nothing is sent, a phone call takes the recording away and nothing
is sent. Those only survive if no audio reaches the server before the release.

**Decision: commit on release.** Record locally while the card is held, exactly as
home-intercom does, and open the link and stream the clip only when the finger lifts without
cancelling. The server buffers the whole clip before playing anyway (players need it whole),
so the only cost is the upload time after release — the same cost home-intercom pays for its
WAV upload, and the card already has a `sending` state for it.

Consequences:

- Upstream's microphone-driven `speak()` and `AudioEngineCapture.kt` are not ported. The
  recorder is home-intercom's `AudioRecorder`, which already solved warm-up, finalisation,
  silent recordings, interruptions and metering for the waveform.
- A failed send keeps the WAV on disk, so "Erneut senden" carries over unchanged.
- The protocol (`AnnouncementLink`, `runLiveAnnouncement`) is reused verbatim; only the
  producer of its `frames` channel differs: a finished clip, chunked, instead of a live tap.
- A future server message such as `{"type":"cancel"}` would allow live streaming with
  slide-to-cancel. Worth proposing upstream; not needed for this plan.

Rejected alternative: open the link at press time and hold the frames back, keeping the
server's 10 s idle timeout alive with empty binary frames. It hides the handshake latency but
depends on empty frames surviving the WebRTC data channel and the gateway bridge, and holds
one of the server's four session slots for every press, including the ones that turn out to
be taps. Revisit only if the release-to-"Gesendet" time is noticeably worse than
home-intercom's.

## Kotlin kernel

Port as one adapted commit, "Ports upstream 4bbab882 (#1101), kernel only, adapted to …", in
the style of the existing ports.

| Upstream file | Treatment |
|---|---|
| `api/APICommands.kt` | Verbatim: `PLAYERS_CMD_PLAY_ANNOUNCEMENT`, `PLAYERS_TTS_ENGINES`, `CONFIG_PLAYERS_GET_VALUE` |
| `api/Request.kt` | Verbatim: `Player.playAnnouncement`, `ttsEngines`, `announcementChime` |
| `api/ServiceClient.kt`, `KtorServiceClient.kt`, `WebRTCTransport.kt` | Verbatim: `openWebRTCDataChannel(label)` |
| `webrtc/WebRTCConnectionManager.kt` | Verbatim: `openDataChannel(label)`, next to `openHttpProxyChannel` |
| `data/announcement/AnnouncementLink.kt` | Verbatim |
| `data/announcement/LiveAnnouncementSession.kt` | Verbatim |
| `api/ConnectionInfo.kt` | **Adapted.** This fork has no `basePath`/`wsUrl`; build `liveAnnouncementUrl` with `URLBuilder` (`WS`/`WSS`, host, port, `/live_announcement`) like `webUrl` |
| `data/announcement/AnnouncementRepository.kt` | **Adapted.** Keep `availability`, `chimeSetting`, `type` as upstream wrote them. Drop `speak`/`record`/`LiveRecording` and the `MicrophoneCapture` parameter. No Compose resources: the clip path reports to its caller instead of `ErrorMessageBus` |
| `data/announcement/MicrophoneCapture.kt`, iOS `AudioEngineCapture.kt` | Not ported (see above) |
| `di/SharedModule.kt`, `IosModule.kt` | Not ported (Koin). `AppGraph` gets `val announcementRepository by lazy { … }` with `webrtcHttpClient` and its own `CoroutineScope(SupervisorJob() + Dispatchers.Default)` |
| Compose UI, `MicrophonePermission*`, Android files, `strings.xml`, `AndroidAutoArtworkProvider.kt` | Not ported |

Fork-only additions, in the same package so they sit next to what they wrap:

- `RecordedAnnouncement.kt` — `AnnouncementRepository.sendClip(playerId, pcm, sampleRate,
  channels, options, onAudioLeftDevice, onResult)`. Chunks the PCM into a pre-filled, closed
  `Channel<ByteArray>` (chunks of ~16 KiB keep the data channel happy) and hands it to
  `runLiveAnnouncement`. Runs in the repository scope, never cancelled by the caller: a closed
  link mid-clip plays the partial clip.
- A `TrackingLink` decorator around the `AnnouncementLink` that notes the first `sendBinary`
  (audio has reached the server) and the text frame after it (the stop: the clip is complete).
  That is where `onAudioLeftDevice` fires, and it is what classifies a failure, without
  touching `LiveAnnouncementSession.kt`:

  | Failure seen | Audio sent? | Stop sent? | Meaning for the card |
  |---|---|---|---|
  | rejected / handshake timeout / no link | no | no | Not played. Safe to resend |
  | link lost while flushing | yes | no | A partial clip **will** play. Resend may play it twice |
  | link lost after stop | yes | yes | The clip plays anyway. Not an error |
  | server `error` after stop | yes | yes | Playback failed (player gone, timeout). Show it |

- `PlayerBarItem` gains `isLocal` (voice is never offered for the phone's own player), and
  optionally `isAnnouncing` for a "Durchsage läuft" line on the tile.

`KmpHelper`, new section `// MARK: - Announcements (intercom tab)`:

```kotlin
val announcementAvailability: NativeStateFlow<AnnouncementAvailability>

/** Streams a finished recording to [playerId]. Never cancellable — see RecordedAnnouncement. */
fun sendRecordedAnnouncement(
    playerId: String,
    pcm: NSData,                 // the WAV's data chunk; copied with usePinned + memcpy
    sampleRate: Int,
    channels: Int,
    onAudioLeftDevice: () -> Unit,
    onResult: (AnnouncementResult) -> Unit,  // flat: played, reason, audioSent, stopSent
)

fun playTextAnnouncement(playerId: String, message: String)  // only if the TTS option is taken
```

Callbacks land on the main thread like every other bridge callback. `AnnouncementResult` is a
flat class with plain `Boolean`s, per `PlayerBarState.kt`'s rule against `Boolean?`.

Tests (commonTest): `LiveAnnouncementSessionTest` and `AnnouncementRequestTest` verbatim;
`ConnectionInfoTest` adapted to the URL builder; `AnnouncementAvailabilityTest` needs
`ktor-client-mock` (upstream has it; add it to `libs.versions.toml` and commonTest, and to
`dependencies.md`). New: `RecordedAnnouncementTest` — chunking, and each row of the table
above against a fake link.

## Swift

New directory `iosApp/iosApp/Intercom/`. Every file from home-intercom keeps its behaviour and
its comments; the table says what has to change.

| home-intercom | Here | Change |
|---|---|---|
| `Features/Rooms/RoomsView.swift` | `IntercomView.swift` | Players instead of rooms. Drop the not-configured and load-failure branches, pull-to-refresh, polling and the HA live-status lifecycle; keep the pop-over, hold hint, haptic warm-up and the background cancel. The gear calls `AppRouter.shared.requestSettings()` or goes |
| `Features/Rooms/RoomCard.swift` | `IntercomCard.swift` | `Room` → `IntercomTarget`. The room symbol becomes `PlayerIcon(iconId)`. Status row: "Aus" for a powered-off player, "Durchsage läuft" if `isAnnouncing` is bridged |
| `Features/Rooms/RoomsViewModel.swift` | `IntercomViewModel.swift` | Loading, polling, live status, room refresh and `/config` go; targets are pushed in from `PlayerBarStore` (`update(targets:)`). No "Alle Räume" card (decision 1). `client.send(wav:target:onBodySent:)` becomes `sender.send(clip:to:onAudioLeftDevice:)`; the held/released/superseded bookkeeping stays as it is. Max length a constant (60 s, the server allows 300) |
| `Features/Rooms/RecordingWaveform.swift` | same | Renamed recorder type only |
| `Models/Room.swift` | `IntercomTarget.swift` | Pure value: player id, name, icon id, isGroup, isPoweredOff. `canReceiveAnnouncement` = in the list and not local |
| `Networking/APIError.swift` | `AnnouncementError.swift` | Pure. Messages for the table above; `mayHaveBeenDelivered` = audio sent |
| `Networking/IntercomClient.swift` (protocol only) | `AnnouncementSending.swift` | Pure protocol, so the view model and its tests compile without `MusicAssistantKit` |
| — | `KmpAnnouncementSender.swift` | Implements it over `KmpHelper.sendRecordedAnnouncement`: reads format and data chunk with `WAVFile`, bridges the callbacks into `async throws`, holds a `UIApplication` background task until the stop has gone out |
| `Audio/AudioRecorder.swift` | `IntercomRecorder.swift` | Format constants (below). `RecordedFile` unchanged |
| `Audio/AudioEngine.swift` | `IntercomAudioSession.swift` | Coexistence with the local player (below) |
| `Audio/WAVFile.swift`, `WAVConverter.swift` | same | Target format; plus a data-chunk reader for the sender |
| `Support/Haptics.swift`, `ImmediatePress.swift`, `ImmediateTouches.swift` | same | Verbatim |
| `Support/Backdrop.swift`, `BackdropStyle.swift` | same | Verbatim; always `.aurora` (decision 4) |
| `Support/Palette.swift` + `CancelColor.colorset` | same | `Color.cancel` and the asset |
| `Networking/*` (HA client, WebSocket, endpoints), `Storage/*`, `RoomStatus`, `RoomIcon`, `IntercomConfig`, `EntityState`, `PreviewIntercomClient` | not ported | Music Assistant replaces Home Assistant; previews get a `PreviewAnnouncementSender` |

**Names.** `AudioFormat` collides with the Kotlin `AudioFormat` that `MusicAssistantKit` exports,
so home-intercom's enum becomes `IntercomAudioFormat`. `AudioEngine` becomes
`IntercomAudioSession` because here it no longer owns the session. The rest is free.

**Format.** home-intercom records 16 kHz mono 16-bit only because Home Assistant's chime is
concatenated in that format. Music Assistant takes 8–96 kHz and renders announcements itself,
so keep mono 16-bit and pick **24 kHz**: full speech band, half the upload of 48 kHz.
`WAVConverter` keeps covering a recorder that hands back something else.

**Audio session.** home-intercom owns the whole session; here `NowPlayingCoordinator` does
whenever the local player is on, and caches the mode it last set. So `IntercomAudioSession`:

- re-applies `.playAndRecord` on every press instead of once per process, after saving the
  current category, mode and options, and restores them exactly when the recording ends;
- never calls `setPreferredSampleRate` — it is session-wide and would resample the local
  player's output;
- deactivates with `.notifyOthersOnDeactivation` only if the session was not already active for
  local playback, and otherwise leaves it running;
- skips the warm-up's category change while the local player is playing (warm-up then only
  allocates the recorder) — changing the category of an active session moves the route.
  Needs a read-only `isPlaying` on `NativeAudioController`.

Options: home-intercom's `[.defaultToSpeaker, .allowBluetooth]` when nothing local plays; while
the local player plays, upstream's `[.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]`, so
the music keeps its route and quality.

**Tab.** `AppTab.intercom` in `AppTabView`, its own `NavigationStack`, label `nav_intercom`,
symbol `megaphone`. Always present; the content shows what applies:
not connected → the connection state; schema < 48 → `ContentUnavailableView` saying the server
is too old; no eligible players → empty state; otherwise the grid. A tab that came and went
with `availability.voice` would disappear on every reconnect. `TabView` builds the tab lazily,
so the recorder warm-up and the haptic engine (both tied to the grid's `.task`) cost nothing
until the tab is opened, as the guidelines ask.

The pop-over overlay lives in the tab's content, so its dim stops at the tab bar and the mini
player accessory. Acceptable for a first version; hoisting it above the `TabView` is polish.

**Strings.** home-intercom's literals are German. They move into `Localizable.xcstrings` with
English source strings and the existing German as the `de` translation.

**Platform.** `NSMicrophoneUsageDescription` in `Info.plist` currently says the app never uses
the microphone; replace it with what upstream says, in this app's name. `docs/USING-THE-APP.md`
gets a section. Every new Swift file goes into `project.pbxproj` by hand (four entries, six
for the pure files the tests compile too).

**Swift tests.** `IntercomViewModelTests` from `RoomsViewModelTests` (minus polling and live
status), `WAVFormatTests`, `AnnouncementErrorTests` (from `SendResultTests` and
`UploadRetrySafetyTests`).

## Behaviour mapping

| home-intercom | Here |
|---|---|
| Room list from `/rooms` + `/rooms/status`, WebSocket status | `PlayerBarStore.players` minus the local player; already filtered to available, enabled, visible |
| Room `unavailable` / `no_play_media` | Not in the list (the kernel drops unavailable players) |
| `max_record_secs` from `/config` | Constant |
| Upload body left the device → "Gesendet" | Stop sent → "Gesendet" |
| HTTP response after playback | `finished` / `error` after playback |
| `APIError.mayHaveBeenDelivered` | Audio reached the server |
| Partial delivery ("Nur N von M Räumen") | No equivalent (one player per clip) |
| Recording too short / silent | Unchanged — nothing reaches the server |

## Decisions (2026-10-09)

1. **No "Alle Räume" card.** Music Assistant has no broadcast and allows four live sessions at
   once. A group player shows up as its own card, and the server fans a group's announcement
   out to its members.
2. **No typed announcements in the tab.** Upstream's *Type* mode has no place in a
   push-to-talk grid. The kernel keeps `AnnouncementRepository.type` and the availability's
   `text` flag, so a sheet can follow without touching Kotlin.
3. **No per-announcement chime or volume.** Neither is sent, so each player's own
   announcement settings apply.
4. **Fixed backdrop.** `Backdrop(style: .aurora)`; no picker, no preference.

## Order of work

1. Kotlin kernel port + fork additions + Kotlin tests. Gates: `iosSimulatorArm64Test`, `detektAll`.
2. Bridge: `KmpHelper` section, `PlayerBarItem.isLocal`. Framework build.
3. Swift: the pure files and their tests first (target, errors, WAV, view model), then
   recorder and session, sender, views, tab, strings, `Info.plist`. Full `xcodebuild test`
   plus an unsigned device build (frameworks and `Info.plist` change).
4. On a device: direct and WebRTC connections; slide-off, too-short and call interruption send
   nothing (watch the server log); local player playing while recording keeps playing and keeps
   its route; Bluetooth headphones; a fifth announcement while four are still playing is
   rejected with the server's reason; background the app mid-send.
5. Docs: `architecture.md` (announcements line, like upstream's), `project-structure.md`
   (`Intercom/`), `dependencies.md` (`ktor-client-mock`), `USING-THE-APP.md`.
