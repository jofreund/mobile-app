# Documentation Index

Agent-facing docs for Taktgeber, a native SwiftUI client for Music Assistant on a Kotlin
kernel. Human-facing setup and build docs are in `../docs/`.

**Last updated:** 2026-09-04

## Read first

| Document | What it covers |
|----------|----------------|
| [project.md](project.md) | What the app is, quick commands, index of the feature notes (imported by `CLAUDE.md`) |
| [architecture.md](architecture.md) | Layers, Swift/Kotlin ownership, the bridge contract, nil-vs-empty rule, session and player state, artwork, local player |
| [project-structure.md](project-structure.md) | Directory map for the kernel, the bridge, and the Swift app; where new code goes |
| [dependencies.md](dependencies.md) | Every library and why, plus what is deliberately absent |
| [guidelines.md](guidelines.md) | Conventions for Swift and Kotlin, pbxproj edits, verification gates, performance rules |
| [perf-and-simplification-plan.md](perf-and-simplification-plan.md) | Numbered, ticked list of performance and simplification work |

## Feature notes (current)

| Document | Status |
|----------|--------|
| [settings-screen.md](settings-screen.md) | Settings, connection setup, login/OAuth, local player section |
| [player-overflow-menu-plan.md](player-overflow-menu-plan.md) | Expanded player's ⋯ menu: autoplay, crossfade, playback speed, transfer queue |
| [volume-control.md](volume-control.md) | Volume slider behaviour and the attempt that must not be repeated |
| [local-player-integration-plan.md](local-player-integration-plan.md) | How the on-device Sendspin player was ported back and gated behind a toggle |
| [kids-favorites-mode.md](kids-favorites-mode.md) | Kids mode: a favorites Cover Flow with basic transport that replaces the shell on a child's device |
| [siri-integration-overview.md](siri-integration-overview.md) | How upstream's Siri integration works; what a port back would need (not built) |
| [carplay.md](carplay.md) | Upstream's CarPlay architecture; removed from this fork, kept as reference |

## Kernel and protocol notes (historical, still accurate for the Kotlin they describe)

These were written when the app was Kotlin Multiplatform with a Compose UI. The Kotlin they
describe — the Sendspin client and the WebRTC transport — is still what ships; the Android
and Compose parts they mention are gone.

- [sendspin-status.md](sendspin-status.md), [sendspin-transport-architecture.md](sendspin-transport-architecture.md), [sendspin-resilient-architecture.md](sendspin-resilient-architecture.md), [sendspin-webrtc-status.md](sendspin-webrtc-status.md)
- [ios_audio_pipeline.md](ios_audio_pipeline.md) — predates the AudioQueue-based `NativeAudioController`; the codec facts hold, the MPV pipeline does not
- [webrtc-completion-summary.md](webrtc-completion-summary.md), [webrtc-refactoring-summary.md](webrtc-refactoring-summary.md), [webrtc-implementation-plan-ARCHIVED.md](webrtc-implementation-plan-ARCHIVED.md)

## Conventions for this directory

- One topic per file; date it at the top; correct it when the code moves.
- `project.md` is imported by `CLAUDE.md` and in turn imports the four "read first" docs, so
  keep those accurate above all.
- Superseded documents are deleted, not kept with a warning banner; git history has them.
