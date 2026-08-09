# Contributing

This is a personal, iOS-only fork of
[music-assistant/mobile-app](https://github.com/music-assistant/mobile-app), maintained for one
person's use. It has no roadmap, no release channel, and no issue triage.

**If you want to contribute to Music Assistant, contribute upstream.** That project is actively
maintained, ships Android and iOS, and has an issue tracker where your work will reach users:
[music-assistant/mobile-app](https://github.com/music-assistant/mobile-app).

Issues and pull requests here may go unanswered. That isn't rudeness — this repository exists to
be forked and read, not to coordinate work.

## If you've forked this

You're welcome to. It's Apache 2.0, like upstream — see [LICENSE](../LICENSE). No attribution to
this fork is expected or wanted; the work worth crediting is the
[Music Assistant project's](https://github.com/music-assistant).

Two things worth knowing before you change anything:

- **The Kotlin core is kept deliberately pickable.** `api/`, `data/` and `webrtc/` track upstream,
  and `upstream` is configured as a fetch-only remote. Moving or reformatting files in those
  directories makes every future `git cherry-pick` a manual exercise. Weigh that against whatever
  the tidy-up buys.
- **Verification is not optional and not slow.** The gates below catch most mistakes before a
  build reaches a device, which matters because a lot of this app's failure modes are silent —
  a projection that stops updating, an image that decodes to nothing, a string that renders as
  its own key.

## Getting set up

[Set up your development environment](DEV-ENVIRONMENT.md), then
[build it](IOS-BUILD-INSTRUCTIONS.md).

## Verification gates

Run all four before committing anything non-trivial:

```bash
JAVA_HOME=/path/to/jdk-21 ./gradlew :composeApp:iosSimulatorArm64Test
CI=true JAVA_HOME=/path/to/jdk-21 ./gradlew detektAll
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphonesimulator -destination "id=<simulator-udid>" -configuration Debug build
xcodebuild test -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphonesimulator -destination "id=<simulator-udid>" -configuration Debug
```

`CI=true` matters for detekt: without it the local run auto-corrects and hides exactly the
findings a clean checkout would fail on.

For anything touching signing, entitlements or the framework, also build for a device — it
exercises provisioning without one attached:

```bash
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphoneos -destination 'generic/platform=iOS' -configuration Debug build
```

## Conventions

- **`gradle.properties` stays out of commits.** It carries a machine-local
  `org.gradle.java.home`, and committing it breaks every other checkout.
- **Adding a Swift file means editing `project.pbxproj` by hand, in four places** — there are no
  file-system-synchronized groups. Copy an existing entry's shape, and check the identifiers you
  invent don't already exist: a duplicate makes `xcodebuild` refuse to read the project, with an
  error that doesn't say why.
- **Prove a new test can fail.** Break the code it covers and watch it go red. Several tests here
  guard silent failures, and a test that cannot fail is worse than none because it reads like
  coverage.
