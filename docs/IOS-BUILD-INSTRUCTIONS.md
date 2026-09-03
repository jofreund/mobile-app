# iOS App Build Guide

Complete guide to build and run **Taktgeber**, the iOS app in this repo, from source.

---

## Environment Verified

| Tool | Required | Tested Version |
|------|----------|----------------|
| macOS | 26 | macOS 26 |
| Xcode | 26 (beta toolchain) | 26.2 (Build 17C52) |
| Xcode Command Line Tools | required | included with Xcode 26.2 |
| JDK | **21 LTS** | Temurin 21.0.10 |
| Swift | 5 language mode | 6.2.3 (included with Xcode) |

> **Critical:** JDK 25 is **not** supported by Gradle 9.6 + Kotlin 2.4.0. Use JDK 21 LTS.
> Install Temurin 21: https://adoptium.net/temurin/releases/?version=21

---

## Prerequisites

### 1. Install JDK 21

```bash
# Verify installed JDKs
/usr/libexec/java_home -V

# Set JAVA_HOME to JDK 21 for the build session
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
```

If JDK 21 is not installed, download from https://adoptium.net/temurin/releases/?version=21

### 2. Install Xcode

Install Xcode 26. This fork targets iOS 26 and is developed against the beta toolchain, so on
this machine only Xcode-beta works — don't switch `xcode-select` back. Accept the license:

```bash
sudo xcodebuild -license accept
```

### 3. Make Gradle wrapper executable (one-time)

```bash
chmod +x ./gradlew
```

### 4. WebRTC framework (one-time download)

The Kotlin core's WebRTC transport (`ktor-client-webrtc`) links against the `WebRTC.xcframework`
binary at `iosApp/Frameworks/WebRTC.xcframework` (gitignored). Fetch it with:

```bash
scripts/fetch-webrtc.sh
```

That downloads the patched M125 build (~15 MB compressed / ~32 MB extracted; the tag and its
provenance are documented in the script), and removes the `DebugSymbolsPath` entries each
slice's `Info.plist` declares for `dSYMs` the release does not ship — Xcode refuses to process an
xcframework with a missing declared path. Re-running is safe: the download is skipped when
present, the fix-up always re-applied.

Expected result: `iosApp/Frameworks/WebRTC.xcframework/` containing slices for:
- `ios-arm64` (physical device)
- `ios-arm64_x86_64-simulator` (simulator)

The xcframework binary ships **without dSYMs** — they live as a separate
`*-dsyms.zip` asset on the same release for opt-in download when you need
to symbolicate a WebRTC frame in a crash report.

The xcframework is referenced by the app target directly and listed in its **Embed Frameworks**
phase with *Embed & Sign*, so Xcode picks the slice, embeds it into the `.app` bundle's
`Frameworks/` folder and signs it with the build's own identity. There is no script involved.

### 5. Build the Kotlin framework

```bash
scripts/build-kotlin-framework.sh                  # debug, simulator + device
scripts/build-kotlin-framework.sh debug simulator  # the fast inner loop
scripts/build-kotlin-framework.sh release device   # what an archive needs
```

This runs Gradle's `link*Framework*` tasks and copies the result to
`iosApp/Frameworks/Kotlin/<Configuration>/<platform>/MusicAssistantKit.framework`, which is
where the app target's `FRAMEWORK_SEARCH_PATHS` look (`$(CONFIGURATION)/$(PLATFORM_NAME)`).
Xcode never runs Gradle: an Xcode build is pure Swift. Re-run the script whenever Kotlin
sources or Gradle files change; Xcode fails with `no such module 'MusicAssistantKit'` when the
framework for the selected configuration and platform is missing.

**First Kotlin build:** 5–15 minutes (Kotlin/Native compiles its dependencies once).
**Subsequent Kotlin builds:** under a minute when nothing changed, a few minutes after edits.
**Xcode builds:** seconds.

---

## Build Commands

### Build and run in Xcode (recommended)

```bash
open iosApp/iosApp.xcodeproj
```

Then in Xcode:
1. Select a simulator or physical device from the toolbar
2. Click the **Run** button (⌘R)

Xcode does not run Gradle — build the Kotlin framework first (step 5 above).

### Build for iOS Simulator (command line)

```bash
# From the mobile-app/ directory:
scripts/build-kotlin-framework.sh debug simulator
xcodebuild \
  -project iosApp/iosApp.xcodeproj \
  -scheme iosApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```


#### Install and Run on Simulator

```bash
# List available simulators
xcrun simctl list devices available

# Boot a simulator (use UUID from list above)
xcrun simctl boot <SIMULATOR_UUID>

# Install the app
xcrun simctl install <SIMULATOR_UUID> \
  ~/Library/Developer/Xcode/DerivedData/iosApp-*/Build/Products/Debug-iphonesimulator/Taktgeber.app

# Launch the app
xcrun simctl launch <SIMULATOR_UUID> com.jofreund.taktgeber-ios
```

### Build for physical device

Physical device builds require valid provisioning:
- Set `TEAM_ID` in `Config.xcconfig`
- Ensure your Apple Developer account can sign for `PRODUCT_BUNDLE_IDENTIFIER`
- Remove `CODE_SIGNING_ALLOWED=NO` from the xcodebuild command
- The device must be registered in your Apple Developer portal

#### Set signing team and bundle ID

Edit `iosApp/Configuration/Config.xcconfig`:

```
TEAM_ID=YOUR_APPLE_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER=com.jofreund.taktgeber-ios
APP_NAME=Taktgeber
IPHONEOS_DEPLOYMENT_TARGET = 26.0
```

The bundle id must match the App Store Connect record exactly (the `-ios` suffix is part of
the registered id); an archive with a different id is rejected at upload. If you fork, pick
your own id here and register it.

Replace `YOUR_APPLE_TEAM_ID` with your Apple Developer Team ID (10-character alphanumeric string found at developer.apple.com/account).

---

## Project Structure

```
mobile-app/
├── iosApp/
│   ├── iosApp.xcodeproj/          # Xcode project
│   ├── iosApp/                    # Swift source files
│   │   ├── iOSApp.swift           # SwiftUI @main entry point
│   │   ├── ContentView.swift      # Root; owns the theme and hands it down
│   │   ├── Shell/                 # Tab shell, routing, toasts
│   │   ├── Home/ Library/ Search/ Settings/ ItemDetails/ Player/
│   │   └── Media/                 # Artwork loading + caching, media-item projection
│   ├── iosAppTests/               # Swift tests (no host app — see DEV-ENVIRONMENT)
│   ├── Configuration/
│   │   └── Config.xcconfig        # TEAM_ID, PRODUCT_BUNDLE_IDENTIFIER, APP_NAME
│   └── Frameworks/
│       └── WebRTC.xcframework     # WebRTC M125 binary (125.6422.02)
├── composeApp/
│   ├── build.gradle.kts           # KMP module build config
│   └── src/
│       ├── commonMain/            # Shared Kotlin core — api, data, webrtc, settings
│       ├── commonTest/            # Tests for that core
│       └── iosMain/               # iOS-specific Kotlin glue
│           ├── MainViewController.kt   # bootstrapKmp()
│           ├── di/IosModule.kt
│           └── di/KmpHelper.kt         # the whole Swift-facing bridge
├── gradle.properties              # JVM memory for Gradle/Kotlin daemons
├── settings.gradle.kts
└── build.gradle.kts
```

---

## Key Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Kotlin Multiplatform | 2.4.0 | Language + toolchain for the shared core |
| Ktor | 3.3.3 | HTTP + WebSocket client (Darwin engine on iOS) |
| Koin | 4.1.1 | Dependency injection |
| kotlinx.coroutines | 1.10.2 | Async/concurrency |
| Coil3 | 3.3.0 | Image loading |
| Kermit | 2.0.8 | Multiplatform logging |
| webrtc-kmp | 0.125.11 | WebRTC remote access (iOS: stubs only) |
| swift-opus | 0.0.2 | Opus audio decoding (SPM) |
| flac-binary-xcframework | 0.2.0 | FLAC decoding (SPM) |
| ogg-binary-xcframework | 0.1.3 | Ogg container (SPM) |
| **WebRTC.xcframework** | **125.6422.02** | **Required binary — see step 5** |

SPM packages are resolved automatically by Xcode at first build.

---

## Gradle Build Tasks

```bash
# Build the KMP iOS framework (what scripts/build-kotlin-framework.sh wraps)
./gradlew :composeApp:linkDebugFrameworkIosSimulatorArm64   # -> composeApp/build/bin/iosSimulatorArm64/debugFramework/
./gradlew :composeApp:linkDebugFrameworkIosArm64            # -> composeApp/build/bin/iosArm64/debugFramework/
./gradlew :composeApp:linkReleaseFrameworkIosArm64          # -> composeApp/build/bin/iosArm64/releaseFramework/

# Run the shared-core tests (on the iOS simulator target)
./gradlew :composeApp:iosSimulatorArm64Test

# Lint — CI=true disables auto-correct, which otherwise hides findings
CI=true ./gradlew detektAll
```

---

## Fixes Applied to Source Code

The following issues were found and fixed to enable iOS/Kotlin-Native compilation:

### 1. `System.currentTimeMillis()` in commonMain

**File:** `composeApp/src/commonMain/kotlin/io/music_assistant/client/api/ServiceClient.kt`
**Problem:** `System.currentTimeMillis()` is JVM-only; Kotlin/Native has no `System` class.
**Fix:** Replaced with `currentTimeMillis()` from the existing `expect/actual` in `utils/PlatformTime.kt`.

### 2. `synchronized()` in commonMain

**File:** `composeApp/src/commonMain/kotlin/io/music_assistant/client/player/sendspin/audio/AudioStreamManager.kt`
**Problem:** `synchronized(lock) {}` is JVM-only; not available in Kotlin/Native.
**Fix:** Replaced `private val decoderLock = Any()` with `private val decoderLock = Mutex()` and all `synchronized(decoderLock) { }` blocks with `decoderLock.withLock { }` (suspend functions) or `runBlocking { decoderLock.withLock { } }` (`close()` non-suspend). Non-local `return` inside the old `synchronized` lambdas was replaced with `return@withLock null` + `?: return`.

### 3. `PRODUCT_BUNDLE_IDENTIFIER` placeholder

**File:** `iosApp/iosApp.xcodeproj/project.pbxproj`
**Problem:** Bundle ID was hardcoded to `com.yourname.musicassistant` (placeholder).
**Fix:** Changed to `"$(PRODUCT_BUNDLE_IDENTIFIER)"` to use the value from `Config.xcconfig`.

### 4. `TEAM_ID` empty in Config.xcconfig

**File:** `iosApp/Configuration/Config.xcconfig`
**Fix:** Populated with the team ID from the existing `DEVELOPMENT_TEAM` in the pbxproj.

### 5. `WebRTC.framework` not embedded in app bundle (dyld crash on launch)

> Historical. Fixes #5 and #6 lived in the `Compile Kotlin Framework` run-script phase, which
> is gone: `WebRTC.xcframework` is now a framework reference on the app target with
> *Embed & Sign*, so Xcode does both jobs. Kept for the symptoms.

**File:** `iosApp/iosApp.xcodeproj/project.pbxproj` — the former `Compile Kotlin Framework` shell script
**Problem:** The build phase script copied `WebRTC.framework` to the linker search path (so the build succeeded), but never embedded it into the `.app` bundle. At runtime, dyld looked for it at `@executable_path/Frameworks/WebRTC.framework`, found nothing, and aborted with:
```
#3  dyld4::halt()
#4  dyld4::prepare()
#5  start()
```
**Fix:** Added to the end of the shell script:
```sh
BUNDLE_FRAMEWORKS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
mkdir -p "$BUNDLE_FRAMEWORKS"
cp -Rf "$OUTPUT_DIR/WebRTC.framework" "$BUNDLE_FRAMEWORKS/"
```

### 6. `WebRTC.framework` signature invalid on physical device

**File:** `iosApp/iosApp.xcodeproj/project.pbxproj` — `Compile Kotlin Framework` shell script
**Problem:** After fix #5, a simulator build worked but deploying to a physical device failed with error `0xe8008014 (The executable contains an invalid signature)` because the framework was initially unsigned (error `0xe800801c`) and then signed with a hardcoded ad-hoc identity (`-`) which physical devices reject.
**Fix:** Sign the embedded framework using `$EXPANDED_CODE_SIGN_IDENTITY` — the Xcode build environment variable that holds the actual developer certificate for device builds and `-` (ad-hoc) for simulator builds:
```sh
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$BUNDLE_FRAMEWORKS/WebRTC.framework"
```
The `:--` fallback ensures ad-hoc signing if the variable is empty (e.g., CLI simulator builds with `CODE_SIGNING_ALLOWED=NO`).

---

## Troubleshooting

### `BUILD FAILED: 25.0.2` (Gradle)

JDK 25 is not supported. Explicitly set `JAVA_HOME` to JDK 21:
```bash
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
```

### `no such module 'MusicAssistantKit'` (Xcode)

The Kotlin framework for the selected configuration and platform hasn't been built. Run
`scripts/build-kotlin-framework.sh` (add `release device` before archiving) and build again.

### `Undefined symbols: _OBJC_CLASS_$_RTCAudioTrack` (Linker)

WebRTC.xcframework is missing from `iosApp/Frameworks/`. Follow step 5 above to download and extract it.

### `The project is damaged and cannot be opened due to a parse error`

Variable references in `project.pbxproj` must be quoted. e.g., use `"$(PRODUCT_BUNDLE_IDENTIFIER)"` not `$(PRODUCT_BUNDLE_IDENTIFIER)`.

### App crashes immediately on launch — `dyld4::halt()` / `dyld4::prepare()` in backtrace

`WebRTC.framework` is not embedded in the app bundle. Check that `WebRTC.xcframework` is listed in the app target's **Embed Frameworks** phase with *Embed & Sign* (Frameworks, Libraries, and Embedded Content in the target's General tab). A clean build (`Product > Clean Build Folder`) then rebuild should resolve it.

### `Failed to verify code signature … WebRTC.framework : 0xe800801c (No code signature found.)`

The framework was embedded but not signed. Its entry in the app target's Frameworks, Libraries, and Embedded Content must say *Embed & Sign*, not *Embed Without Signing*.

### `Failed to verify code signature … WebRTC.framework : 0xe8008014 (The executable contains an invalid signature.)`

The framework was signed with an ad-hoc identity (`-`) but is being installed on a physical device which requires a developer certificate. With *Embed & Sign* Xcode signs it with the build's own identity; if this reappears, a stale copy from the old script is being embedded — clean the build folder.

### `Unresolved reference 'synchronized'` or `'System'` (Kotlin/Native)

JVM-only APIs in `commonMain`. Use KMP-compatible alternatives (`Mutex.withLock { }`, `currentTimeMillis()`).

### Long first Kotlin build (5–15 min)

The first `scripts/build-kotlin-framework.sh` compiles every Kotlin/Native dependency into `~/.konan`. Later runs reuse that cache and finish in well under a minute when nothing changed; Xcode builds never wait on it.

---

## Known Limitations (iOS)

Everything this section used to list as unimplemented — WebRTC, OAuth — now works. What remains
are deliberate absences, not gaps:

- **No local playback.** The Sendspin on-device player was removed. This app controls remote
  players and produces no audio.
- **No lock screen or Control Center, and no background audio.** A consequence of the above, not a
  separate omission: iOS grants those surfaces to the app that is actually producing audio, so a
  pure remote control cannot have them. Restoring them means restoring local playback.
- **No CarPlay and no Siri.** Both removed. CarPlay additionally needs the restricted
  `com.apple.developer.carplay-audio` entitlement, which Apple grants per account on request.
- **Expanded player overflow menu** — queue transfer, DSP, playback speed, lyrics, power toggle —
  exists in Kotlin but has no Swift entry point yet. This one is a genuine gap.
