# Project Structure

One Gradle module and one Xcode project.

```
composeApp/src/commonMain/   Kotlin kernel (shared with upstream; keep cherry-pickable)
composeApp/src/commonTest/   Kotlin tests (run on the iOS simulator target)
composeApp/src/iosMain/      Swift-facing bridge + iOS actuals
iosApp/                      The SwiftUI app, widget extension, and Swift tests
scripts/                     Framework build, WebRTC fetch, icon sync
docs/                        Human docs: setup, build, contributing, using the app
.claude/                     Agent-facing docs (this directory)
```

The Gradle module is still `:composeApp` and its directory `composeApp/` on purpose: every
upstream path starts there, so renaming would make each cherry-pick a path-rewriting job. The
framework it produces is `MusicAssistantKit`.

## Kotlin kernel — `composeApp/src/commonMain/kotlin/io/music_assistant/client/`

```
api/            ServiceClient, KtorServiceClient, RpcEngine, Request/Answer, Event, transports
auth/           AuthenticationManager, OAuthCallback, AuthState
connection/     ConnectionManager (auto-connect on launch and foreground)
data/           MainDataSource, PlayerBarState, PlayerPositionTracker, LocalPlayerController
  model/server/   DTOs as the server sends them (+ events/)
  model/client/   Domain models: PlayerData, QueueInfo, AppMediaItem and items/
  factory/        DTO → domain mappers
  repository/     MediaItemRepository (fetch + search + item-change events)
di/             SharedModule, WebRTCModule, initKoin
logging/        Kermit writers, in-memory log, LogSharer
platform/       PlatformContext
player/         MediaPlayerController (expect), sendspin/ protocol client
settings/       SettingsRepository and preference types
ui/             Value types that outlived Compose: ThemeSetting, DataState, ItemAction,
                PlayerAction/QueueAction, LibraryCategory. No UI here despite the name.
utils/          SessionState, ConnectionData, dispatchers, JSON, time, network monitor
webrtc/         SignalingClient, WebRTCConnectionManager, DataChannelWrapper, WebRTCHttpProxy
```

## Bridge — `composeApp/src/iosMain/kotlin/io/music_assistant/client/`

```
MainViewController.kt        bootstrapKmp(): Koin init, crash handler
di/KmpHelper.kt              Everything Swift calls. Flat members, completion callbacks.
di/IosModule.kt              iOS Koin bindings (PlatformContext, Ktor WebRTC engine)
bridge/                      NativeFlow, NativeStateFlow, NativeSuspend, Cancellable
logging/                     os_log bridge, log sharing
player/                      PlatformAudioPlayer (Swift sink interface), MediaPlayerController actual
player/sendspin/audio/       FLAC/Opus decoder actuals (delegate to Swift)
utils/                       Darwin HttpClient, dispatchers, time, NetworkMonitor actuals
```

## Swift app — `iosApp/iosApp/`

```
iOSApp.swift        Entry point: bootstrapKmp, AppRouter.start, scenePhase → foreground/background
Shell/              AppShellRootView, AppRouter + AppRootPolicy, AppTabView, ToastHost, OAuthWebSession
Home/               HomeView (recommendation rows, edit mode), RecommendationRowTitle
Library/            LibraryView, LibraryListView (search/sort/filter/paging), BrowseView, filter sheet
Search/             SearchView, SearchSections
ItemDetails/        Album/Playlist/Podcast/Audiobook/Artist/Genre detail screens
Player/             MiniPlayerView, ExpandedPlayerView, PlayerBarStore, sliders, queue, sheets
Media/              MediaItem, ArtworkView/Loader/DiskCache, SVGRasterizer, MAWebRTCURLProtocol, ItemContextMenu
Settings/           SettingsView, ConnectionSetupView/Store, QrScanView, LocalPlayerSection
LiveActivity/       PlayerActivityController, PlayerActivityShared (also compiled into the widget)
LocalPlayer/        LocalPlayerActivation, NativeAudioController, AudioDecoders, NowPlayingCoordinator
Localizable.xcstrings, Assets.xcassets, Info.plist, PrivacyInfo.xcprivacy
```

```
iosApp/TaktgeberWidgets/     Live Activity widget extension (does not link MusicAssistantKit)
iosApp/iosAppTests/          XCTest; compiles the source files under test directly
iosApp/Frameworks/           gitignored: WebRTC.xcframework, Kotlin/<Config>/<platform>/
iosApp/Configuration/        Config.xcconfig (bundle id, team, deployment target)
```

## Where new code goes

| What | Where |
|------|-------|
| A screen, a sheet, a store, navigation | `iosApp/iosApp/<Feature>/` |
| Pure value logic worth a unit test | Its own Swift file, compiled into both targets (see guidelines) |
| A new server command or DTO | `api/Request.kt`, `data/model/server/` — upstream's shape |
| A new bridge call | `KmpHelper.kt`, next to its neighbours, with a completion or a `NativeStateFlow` |
| A setting the UI reads | `SettingsRepository` + a `KmpHelper` get/set pair (moving to `@AppStorage` is planned) |

## Key files

- `KmpHelper.kt` — the bridge surface; read its section headers first.
- `MainDataSource.kt` — player/queue projection and optimistic overrides.
- `KtorServiceClient.kt` / `RpcEngine.kt` — connection lifecycle and request correlation.
- `PlayerBarStore.swift` — how Swift consumes `PlayerBarState`.
- `AppRootPolicy.swift` — what the app shows at the top level, and why.
- `project.pbxproj` — edited by hand when a Swift file is added (no synchronized groups).
