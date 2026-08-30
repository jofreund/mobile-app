# Taktgeber — a native iOS client for Music Assistant (personal fork)

> **This is not the official Music Assistant app.** It is a personal fork of
> [music-assistant/mobile-app](https://github.com/music-assistant/mobile-app), rebuilt as an
> iOS-only, native SwiftUI client. It is unsupported, has no release channel, and is developed
> for one person's use.
>
> If you want the official app — Android and iOS, actively maintained — go to
> [music-assistant/mobile-app](https://github.com/music-assistant/mobile-app). Please report bugs
> there only if you can reproduce them in *their* app; issues caused by this fork are not theirs
> to fix.

A client for a [Music Assistant](https://github.com/music-assistant/server) server: browse your
library, control your players, manage groups and queues.

## What's different from upstream

Upstream is Kotlin Multiplatform + Compose Multiplatform, shipping Android and iOS from one
codebase. This fork keeps the Kotlin core and replaces everything above it.

| | Upstream | This fork |
|---|---|---|
| Platforms | Android + iOS | iOS only |
| UI | Compose Multiplatform | Native SwiftUI |
| Local playback | Sendspin on-device player | Sendspin on-device player (optional, off by default) |
| CarPlay / Android Auto | Both | Neither |
| Siri / Assistant | Both | Neither |

**The Kotlin shared core is kept, not rewritten.** The protocol client (Ktor WebSocket JSON-RPC
with request correlation and partial-batch reassembly), the data layer, and the WebRTC
HTTP-over-datachannel proxy for remote access are upstream's work and remain in Kotlin, compiled
into a static framework that Swift imports. Reimplementing that was estimated at 25–40 weeks of
risk for no user-visible benefit. What was replaced is the UI layer, where Compose could not
participate in UIKit's interactive pop transition, sheet detents, `.searchable`, context-menu
previews, native scroll physics, Dynamic Type, or VoiceOver rotors.

### Local playback

The fork originally removed the on-device Sendspin player entirely ("remote control only"),
which cost the surfaces iOS grants only to the app actually producing audio: lock screen and
Control Center integration, and background audio. The player has since been ported back from
upstream — including upstream's Noise-encrypted protocol — behind a Settings toggle that is
**off by default**. With it off, the app behaves exactly as before (pure remote control, lock
screen driven by the Live Activity); with it on, the phone registers as a Music Assistant
player, and while it is the one playing, the system's own Now Playing surface takes over the
lock screen.

## Requirements

- iOS 26.0 or later
- Xcode 26 (this fork is developed against the beta toolchain)
- JDK 21 — Gradle 8.13 / Kotlin 2.4 do not support JDK 25
- A reachable [Music Assistant server](https://github.com/music-assistant/server). Tested against
  schema 59; a server is refused only once its `min_supported_schema_version` climbs past that

## Building

```bash
./gradlew :composeApp:iosSimulatorArm64Test    # Kotlin core tests
CI=true ./gradlew detektAll                    # lint
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphonesimulator -destination "id=<simulator-udid>" build
```

Open `iosApp/iosApp.xcodeproj` in Xcode to run. The Kotlin framework builds automatically via a
run-script phase; there is no separate step. `JAVA_HOME` must point at JDK 21 in the environment
Xcode is launched from.

See [IOS-BUILD-INSTRUCTIONS.md](docs/IOS-BUILD-INSTRUCTIONS.md) and
[DEV-ENVIRONMENT.md](docs/DEV-ENVIRONMENT.md) for the longer version, and
[USING-THE-APP.md](docs/USING-THE-APP.md) for what the app actually does.

## Layout

```
composeApp/src/commonMain/   Kotlin shared core — api, data, webrtc, settings
composeApp/src/iosMain/      Swift-facing bridge (KmpHelper, NativeFlow)
iosApp/                      The SwiftUI app
```

The Gradle module is still called `composeApp` and the framework `MusicAssistantKit`. The module
name is a historical artefact kept deliberately: every upstream path begins with `composeApp/`,
so renaming the directory would make each cherry-pick from upstream a path-rewriting exercise.

## Upstream

`upstream` is configured as a fetch-only remote so protocol fixes can still be picked up:

```bash
git fetch upstream
git log --oneline main..upstream/main
```

In practice the useful surface is small — the shared core is stable, and most upstream churn is
in the Compose UI this fork deleted.

## Licence

Apache License 2.0, inherited from upstream — see [LICENSE](LICENSE). Music Assistant and its
server are the work of the [Music Assistant project](https://github.com/music-assistant) and its
contributors; this fork claims none of it.
