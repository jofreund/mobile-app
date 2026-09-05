# Taktgeber — native iOS client for Music Assistant

A personal, iOS-only fork of [music-assistant/mobile-app](https://github.com/music-assistant/mobile-app):
a native SwiftUI app on the upstream Kotlin kernel (protocol, session, player state), which is
compiled into a static framework the app imports. Controls players and queues on a
[Music Assistant server](https://github.com/music-assistant/server); optionally acts as a player itself.

## Quick Commands

```bash
# Kotlin kernel tests and lint
JAVA_HOME=/path/to/jdk-21 ./gradlew :composeApp:iosSimulatorArm64Test
CI=true JAVA_HOME=/path/to/jdk-21 ./gradlew detektAll

# Build the Kotlin framework. Xcode's first build phase does this itself (gated on a source
# hash) for the configuration and platform it is building; run it by hand for the others.
scripts/build-kotlin-framework.sh            # debug, simulator + device
scripts/build-kotlin-framework.sh release device   # before an archive
open iosApp/iosApp.xcodeproj

# Swift build + tests
xcodebuild test -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphonesimulator -destination "id=<simulator-udid>" -configuration Debug
```

First checkout: `scripts/fetch-webrtc.sh` (vendors `WebRTC.xcframework`), then the framework
script. See `docs/IOS-BUILD-INSTRUCTIONS.md`.

## Features

- Players, groups and queues: transport, volume, shuffle/repeat, sleep timer, queue editing,
  transfer to another player, autoplay/crossfade/playback speed
- Home recommendations with edit mode; Library with search, sort, filters and paging; Browse;
  Search; detail screens for every media type; context menus with favorite, playlist and
  mark-played actions
- Authentication: login/password, OAuth (`ASWebAuthenticationSession`), long-lived token;
  per-server tokens with auto-login
- Remote access over WebRTC (signaling server + data channel proxy), QR-scanned remote id
- Lock screen / Dynamic Island Live Activity with play/pause for the selected player
- Optional on-device player (Sendspin, Noise-encrypted), off by default

## Architecture

@import .claude/architecture.md
@import .claude/project-structure.md
@import .claude/dependencies.md
@import .claude/guidelines.md

## Feature notes

- **Settings**: `.claude/settings-screen.md` — server connection, authentication flows, local player configuration
- **Expanded player ⋯ menu**: `.claude/player-overflow-menu-plan.md` — Autoplay, Crossfade, Playback speed, Transfer queue, and why each is gated the way it is
- **Volume**: `.claude/volume-control.md`
- **Local player**: `.claude/local-player-integration-plan.md` — how Sendspin was ported back and gated
- **Kids mode**: `.claude/kids-favorites-mode.md` — the favorites carousel that replaces the shell on a child's device, and why "favorites of the signed-in account" is the source
- **CarPlay & Siri**: removed from this fork. `.claude/carplay.md` and `.claude/siri-integration-overview.md` describe upstream's versions for a possible port back
- **Performance and simplification**: `.claude/perf-and-simplification-plan.md` — the numbered plan; tick items there

Full index: `.claude/README.md`.
