# Dependencies

Source of truth: `gradle/libs.versions.toml` and `iosApp/iosApp.xcodeproj/project.pbxproj`.
Update this file when either changes.

## Kotlin (`composeApp`)

| Library | Purpose |
|---------|---------|
| Kotlin 2.4 Multiplatform + `kotlinx.serialization` | Kernel language and JSON |
| `kotlinx-coroutines-core` | Flows and structured concurrency |
| `kotlinx-atomicfu` | Lock-free counters in the transport layer |
| Ktor client: core, websockets, kotlinx-json, darwin engine | WebSocket JSON-RPC to the server |
| Ktor client WebRTC (`ktor-client-webrtc`, experimental) | Peer connection and data channels for remote access |
| multiplatform-settings (no-arg) | `SettingsRepository` over `NSUserDefaults` |
| Kermit | Logging, bridged to `os_log` in debug |
| cryptography-kotlin (core + CryptoKit provider) | Noise handshake for the encrypted Sendspin protocol |

Test: `kotlin-test`, `kotlinx-coroutines-test`, Turbine, `multiplatform-settings-test`.
Lint: detekt with `detekt-formatting`, config in `config/detekt/detekt.yml`.

## Swift (`iosApp`)

| Dependency | Purpose |
|------------|---------|
| `MusicAssistantKit.framework` (built from `composeApp`) | The Kotlin kernel, statically linked |
| `WebRTC.xcframework` (vendored; `scripts/fetch-webrtc.sh`) | Native WebRTC used by Ktor's iOS engine; Embed & Sign |
| `swift-opus` (SPM) | Opus decoding for the local player |
| `flac-binary-xcframework`, `ogg-binary-xcframework` (SPM) | FLAC decoding for the local player |
| Music Assistant shared icons (vendored; `scripts/sync_shared_icons.py`) | Player/device icons as an asset catalog |

System frameworks that carry real weight: `ActivityKit` (Live Activity), `WidgetKit`,
`AVFoundation` / `AudioToolbox` (local player), `MediaPlayer` (Now Playing), `WebKit`
(SVG rasterization), `VisionKit` (QR scanning), `AuthenticationServices` (OAuth).

## Toolchain

- Xcode 26+ (developed against the beta), iOS 26.0 deployment target.
- JDK 21 for Gradle only. `scripts/build-kotlin-framework.sh` runs it; the app target's "Build
  Kotlin Framework" phase calls that script with `--if-changed`, so Xcode runs Gradle only when
  Kotlin or Gradle files changed (never in CI, which passes `KOTLIN_FRAMEWORK_PREBUILT=YES`).
- Gradle 9.6 with the Kotlin/Native `smallBinary` option for release links.

## Deliberately absent

Compose Multiplatform, Coil, Navigation3, Android/Media3, webrtc-kmp, mDNS, CarPlay and
SiriKit — all removed with the native rewrite. Don't reintroduce a Kotlin UI or image library;
the Swift side owns those concerns.
