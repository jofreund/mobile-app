# Development environment

## Requirements

- **macOS with Xcode 26.** This fork targets iOS 26 and is developed against the beta toolchain.
- **JDK 21 LTS.** Gradle 9.6 / Kotlin 2.4 do not support JDK 25. `JAVA_HOME` must point at it in
  whatever environment Xcode is launched from — including when launched from the Dock, where a
  shell profile won't reach it (`launchctl setenv JAVA_HOME …`).

[IOS-BUILD-INSTRUCTIONS](IOS-BUILD-INSTRUCTIONS.md) has the full step-by-step, including the
WebRTC framework and signing.

## Structure

One Gradle module and one Xcode project:

```
composeApp/src/commonMain/   Kotlin shared core — api, data, webrtc, settings, auth
composeApp/src/commonTest/   Tests for that core
composeApp/src/iosMain/      Swift-facing bridge (KmpHelper, NativeFlow) + iOS actuals
iosApp/                      The SwiftUI app and its tests
```

`composeApp` builds a static `MusicAssistantKit.framework` that `iosApp` imports. Xcode drives
that build through a run-script phase, so there's no separate step — but it does mean Xcode needs
a working JDK.

Two names are historical and deliberately unchanged: the module is `composeApp` though it
contains no Compose, and its directory prefixes every upstream path, so renaming it would make
every future cherry-pick a path-rewriting exercise.

There is no Android target. `androidApp` and `androidMain` were removed when this fork went
iOS-only; anything in upstream's docs referring to them does not apply here.

## Tests

Kotlin, run on the iOS simulator target:

```bash
JAVA_HOME=/path/to/jdk-21 ./gradlew :composeApp:iosSimulatorArm64Test
```

Swift:

```bash
xcodebuild test -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphonesimulator -destination "id=<simulator-udid>" -configuration Debug
```

`iosAppTests` has **no host application**. `Bundle.main` there is the xctest bundle, not the app,
so anything needing app resources has to reach the repo another way — via `#filePath`, for
instance. Pure-logic types can be compiled into both targets by adding a second `PBXBuildFile`
entry for the same file reference; `QueueMoveMath.swift` and `SVGRasterizer.swift` do this.

## Lint

```bash
CI=true JAVA_HOME=/path/to/jdk-21 ./gradlew detektAll
```

`CI=true` disables auto-correct. Without it, a local run silently rewrites your working tree and
passes on findings a clean checkout would reject.

## Running a server locally

```bash
./scripts/run-local-ma.sh
```

Starts a Music Assistant server at `http://localhost:8095` in Docker, with data under `.server`.
