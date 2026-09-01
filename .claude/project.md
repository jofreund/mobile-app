# Music Assistant KMP Client

Cross-platform music player client for [Music Assistant Server](https://github.com/music-assistant/server).
Built with Kotlin Multiplatform + Compose Multiplatform for Android and iOS.

## Quick Commands

```bash
# Android
./gradlew :androidApp:assembleDebug
./gradlew :androidApp:installDebug

# iOS - open in Xcode
open iosApp/iosApp.xcodeproj

# Tests
./gradlew :androidApp:testDebug
```

## Features

- Queue management and playback control for Music Assistant players
- Queue-wide options in the expanded player's ⋯ menu: Autoplay, Crossfade, transfer to another player
- Library browsing (Artists, Albums, Tracks, Playlists)
- Authentication: login/pass, OAuth, long-lived access token
- Remote access via WebRTC (planned - see `.claude/webrtc-implementation-plan.md`)
- Built-in player with Sendspin protocol support
- Local music playback (platform-specific)
- Android Auto / CarPlay support

## Architecture

@import .claude/architecture.md
@import .claude/project-structure.md
@import .claude/dependencies.md
@import .claude/guidelines.md

## UI Documentation

- **Settings Screen**: See `.claude/settings-screen.md` for complete documentation on server connection, authentication flows, and local player configuration
- **Expanded Player**: See `.claude/player-overflow-menu-plan.md` for the header ⋯ menu — Autoplay, Crossfade and "Transfer queue" — and why each is gated the way it is
- **CarPlay & Siri**: See `.claude/carplay.md` for CarPlay architecture, template constraints, and the Siri media-domain integration (`INPlayMediaIntent` donation, `INUpdateMediaAffinityIntent`, `INSearchForMediaIntent`)

## Planned Features

- **WebRTC Remote Access**: See `.claude/webrtc-implementation-plan.md` for comprehensive implementation plan, protocol details, and architecture design
- **Local Player (Sendspin) Integration**: See `.claude/local-player-integration-plan.md` for the plan to port the on-device Sendspin player back from upstream (restores background audio and lock-screen/Control Center integration)
