# Architecture

A native SwiftUI app on a Kotlin kernel. Swift owns everything a user sees or touches; Kotlin
owns the protocol, the session, and the player and queue state, compiled into a static
`MusicAssistantKit.framework` that Swift imports. The kernel is upstream's
(`music-assistant/mobile-app`) and is kept cherry-pickable; upstream's Compose UI is gone.

## Layers

```
SwiftUI views                      iosApp/iosApp/**
  │  @Observable stores            PlayerBarStore, ConnectionSetupStore, AppRouter, …
  ▼
KmpHelper                          composeApp/src/iosMain/…/di/KmpHelper.kt
  │  the only Kotlin object Swift calls; NativeStateFlow / NativeFlow / NativeSuspend / Cancellable
  ▼
Kotlin kernel                      composeApp/src/commonMain/…
  ServiceClient (KtorServiceClient + RpcEngine)   WebSocket JSON-RPC, correlation, event stream
  AuthenticationManager                            per-server tokens, auto-login, OAuth callback
  MainDataSource                                   players + queues → PlayerBarState, optimistic overrides
  MediaItemRepository, *Factory                    server DTO → client model
  SettingsRepository                               multiplatform-settings over NSUserDefaults
  webrtc/                                          signaling + HTTP-over-data-channel proxy (remote access)
  player/sendspin                                  on-device player protocol (optional, off by default)
  ▼
Music Assistant server             direct WebSocket, or a WebRTC data channel
```

## Ownership

**Swift owns:** every screen, navigation, the root policy (`AppRootPolicy`: Main vs. Settings,
auto-login splash, reconnection banner, schema-floor alert), the artwork pipeline, the Live
Activity, toasts, theme, UI-only settings (`AppPreferences`), deep-link and OAuth-callback URL
parsing (`DeepLinks.swift`), the local player's audio sink and Now Playing integration.

**Kotlin owns:** the wire protocol and its state machine (`SessionState`), authentication, the
projection of server events into `PlayerBarState`, optimistic feedback for player actions, the
WebRTC transport, the Sendspin client, and persistence of settings.

The rule for new code: UI logic goes in Swift. Kotlin gains code only when the server, the
session, or the player state model needs it — and then in the style of the surrounding upstream
code, so a later cherry-pick still applies.

## The bridge

`KmpHelper` is a Kotlin `object` (a Koin component) that exposes flat, Swift-friendly members.
Four primitives under `composeApp/src/iosMain/…/bridge/` carry everything:

- `NativeStateFlow<T>` — `value` for a synchronous read, `subscribe(onEach:)` for updates. Fires
  once immediately with the current value, then on every change. Callbacks land on the main
  thread.
- `NativeFlow<T>` — `subscribe(onEach:onError:)` for non-state flows (toasts, item changes).
  Single-consumer sources (`ErrorMessageBus` is a `Channel`) must have exactly one subscriber.
- `NativeSuspend<T>` — a one-shot `invoke(onResult:onError:)`; no built-in timeout.
- `Cancellable` — every subscription returns one. Swift keeps it for the intended lifetime and
  cancels it in `deinit`, `stop()`, or when a `.task` ends. A dropped handle is a leak of a
  main-thread collector.

Fetchers on `KmpHelper` take completion closures and wrap their suspend calls in
`withTimeoutOrNull(FETCH_TIMEOUT_MS)` (30 s — a lost-reply guard, not a latency budget).

**The nil-vs-empty rule.** A fetcher's completion receives `nil` only on timeout. An RPC
*failure* arrives as `[]`, because callers do `getOrNull() ?: emptyList()`. Since
`sendRequest` gives up after 10 s when the connection isn't ready, a first load on a fresh
install can legitimately return `[]`. `KmpHelper.readyForCommands` exists for this: empty *and*
not ready means the load failed, not that the library is empty. Every screen that renders a
fetch result must make that distinction, and retry-on-connect subscriptions should fire on the
not-ready → ready edge, seeded from the current value.

**Interop gotchas.**
- `NativeStateFlow<T>`/`NativeSuspend<T>` lose Swift's automatic bridging when `T` is `String`
  or `List<X>`: cast with `as? String` / `as? [X]` at the call site. Class-typed `T` bridges
  cleanly. `Boolean` arrives as `KotlinBoolean` (`.boolValue`), `Int?` as `KotlinInt?`.
- Kotlin sealed hierarchies export as classes: `SessionState.Connected`,
  `SessionState.ConnectedDirect`, `DataConnectionStateAuthenticated`, `AuthProcessStateFailed`.
  Match with `case let x as …` / `is`.
- Top-level Kotlin declarations live on a `<File>Kt` class (`ServerInfoKt.LOCAL_SCHEMA_VERSION`,
  `MainViewControllerKt.bootstrapKmp()`).
- Kotlin objects reached from Swift compare through `NSObject.isEqual`, which Kotlin/Native
  routes to `equals` — structural for data classes.

## Session state

`ServiceClient.sessionState` is a `StateFlow<SessionState>`:
`Disconnected.{Initial, ByUser, NoServerData, Backgrounded, Error}` → `Connecting` →
`Connected.{Direct, WebRTC}` (carrying `ConnectionData`: server info, user, auth process, token)
→ `Reconnecting.{Direct, WebRTC}`. `ConnectionData.dataConnectionState` derives
`AwaitingServerInfo` / `AwaitingAuth` / `Authenticated`.

Swift reads it through `KmpHelper.sessionState`. `AppRouter` maps each value to a pure
`RootSession` and feeds `AppRootPolicy`, which decides the root destination, the splash (with
a process-lifetime latch), the banner, and whether the server's
`min_supported_schema_version` has climbed past `LOCAL_SCHEMA_VERSION`. The router starts in
`iOSApp.init`, right after `bootstrapKmp()`, so the latch sees every transition.

`AuthenticationManager` persists one token per server identifier, decides
`willAutoLoginOnLaunch` at construction, and handles the OAuth callback URL; Swift supplies
the `ASWebAuthenticationSession` through `authManager.oauthHandler`.

## Player state

`MainDataSource` (on `Dispatchers.IO`) combines server players, queue infos, sorting, and two
override maps — play-state and favorite — into `List<PlayerData>`, then projects the selected
player into `PlayerBarState`. The combine is `conflate()`d, not debounced: a burst of events
collapses to one rebuild, but a tap's optimistic feedback never waits for silence.

Optimistic overrides follow one pattern: set on send, cleared by the confirming server event,
rolled back on send failure, reverted by a timeout. Seek and skip drop position anchors into
`PlayerPositionTracker`, which is the live-position source of truth (`observePlayerBarPosition`).

Only the selected player carries `queueItems` and `currentItemChapters`; the expanded player is
the one place a queue is drawn and it shows the selected player alone, so other players' queues
would cross the bridge for nobody. Selection is an input to the projection, so the emission that
moves it carries the new player's queue.

On the Swift side `PlayerBarStore` subscribes to `playerBarState`, caches queue projections by
Kotlin object identity, and publishes `PlayerBarItemView` values that are `Equatable` over every
stored field, so SwiftUI skips unchanged rows. `MiniPlayerView` and `ExpandedPlayerView` read
from it. The Live Activity does not: `PlayerActivityController` subscribes to
`liveActivityState`, a `LiveActivitySnapshot` of the six fields the card shows, distinct on those
alone, so a volume echo or queue edit never wakes ActivityKit.

## Artwork

`ArtworkView` → `ArtworkLoader` (in-flight de-duplication via `SharedLoadRegistry`, a cost-limited
`NSCache`) → `ArtworkDiskCache` (already-downsampled bitmaps, FNV-1a file names, 30-day expiry,
throttled trim) → network. `mawebrtc://` URLs resolve through `MAWebRTCURLProtocol`, which calls
`KmpHelper.loadArtworkBytes` so remote-access images travel the WebRTC proxy. Genre tiles are
SVG, rendered by `SVGRasterizer` through one serialized `WKWebView` that is torn down after
30 s idle. MA artwork URLs carry an empty checksum, so caches expire by age, not by signal.

## Local player (Sendspin)

Off by default. When `sendspinEnabled` is on, `LocalPlayerActivation` (Swift) builds
`NativeAudioController` and `NowPlayingCoordinator` and registers the controller as
`PlatformPlayerProvider.player`; Kotlin's `SendspinClient` decodes and buffers audio and writes
PCM into it through `MediaPlayerController`. iOS grants lock screen and Control Center only to
the app producing audio, so those surfaces exist only while the local player plays; otherwise
the Live Activity (`PlayerActivityController`) is the lock-screen presence.

## The object graph

`AppGraph` (`di/AppGraph.kt`) wires every singleton by hand, in dependency order, with the two
that must observe from launch (`ConnectionManager`, `AuthenticationManager`) eager and the heavy
ones (`MainDataSource`, `LocalPlayerController`, `SendspinClientFactory`) lazy. Platform inputs
(the settings store, `PlatformContext`, the WebRTC engine) come in through its constructor from
`bootstrapKmp()`. There is no container: a missing dependency is a compile error. Swift reaches
the graph only through `KmpHelper`.

## Threading

Bridge callbacks run on the main thread (`KmpHelper.mainScope`). `MainDataSource` and the
service client work on IO; Sendspin decoding on `Dispatchers.Default` and its playback loop on
`audioDispatcher` (a high-priority GCD queue). Swift stores are `@MainActor`.

## Errors and messages

Server RPC errors flow through `ErrorMessageBus` → `KmpHelper.toasts` → the single `ToastHost`
in `AppShellRootView`. `RpcEngine` logs every error answer before the caller sees it, so a
probe for an unsupported command is never silent.

## Kotlin conventions that survive from upstream

- No non-null assertions (`!!`) in live code.
- Prefer `when` over `if-else` chains; safe calls and the Elvis operator over null checks.
- Log with Kermit: `Logger.withTag("Component").e(e) { "message" }`.
- Wrap async results in `DataState<T>` (Loading / Data / Error / NoData).
