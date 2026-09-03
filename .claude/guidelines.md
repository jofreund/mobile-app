# Development Guidelines

## Where code goes

| What | Where |
|------|-------|
| Anything a user sees or navigates | Swift, `iosApp/iosApp/<Feature>/` |
| Root-level app policy, artwork, Live Activity, audio sink | Swift |
| Protocol, session, auth, player/queue projection, settings persistence | Kotlin `commonMain` |
| A Swift-callable entry point | `KmpHelper.kt` |
| Platform actuals for the kernel | `iosMain` |

Kotlin under `api/`, `data/`, `webrtc/`, `player/sendspin` tracks upstream. Don't move,
rename, or reformat those files for tidiness; every change there is a future cherry-pick
conflict. Pure deletions of dead code are fine.

## Swift

- **Stores are `@Observable` and `@MainActor`.** Subscribe to Kotlin in `start()` (or a view's
  `.task`), keep every `Cancellable`, cancel in `stop()`/`deinit`. One `AppRouter`, one
  `ToastHost`, one `PlayerBarStore` per shell.
- **Projections are `Equatable` over every stored field.** Values handed to SwiftUI from a
  Kotlin flow are rebuilt per emission; without a full conformance every row body re-runs. An
  id-only `==` hides updates; never do that.
- **Honour the nil-vs-empty rule** (`architecture.md`): `nil` from a fetcher means timeout,
  `[]` means either "empty" or "failed while not ready". Check `KmpHelper.readyForCommands`.
- **No debounce on tap paths.** Optimistic feedback must reach the screen on the next frame.
  Coalesce with `conflate`-style logic, never with a fixed quiet period.
- **Do nothing at launch that a feature toggle could defer.** `LocalPlayerActivation` is the
  pattern: build the audio stack only when the setting is on.
- **Strings** go in `Localizable.xcstrings` and are read with `String(localized:)`. A missing key
  renders as the key itself, so look at every new string once on screen.
- **Adding a Swift file means editing `project.pbxproj` by hand**, in four places for an
  app-only file (build file, file reference, group child, Sources phase) and six for a file
  the tests also compile. Copy a neighbour's entries; choose an unused 4-character id prefix
  and check it with `grep -c`. A duplicate id makes Xcode refuse the project without saying why.
- **Tests are XCTest**, in `iosApp/iosAppTests/`, and the test target compiles the sources
  under test directly (no `@testable import`, no `MusicAssistantKit`). Put testable logic in
  a pure-Swift file with no Kotlin imports, and register it in both targets.
- Don't drive the Simulator UI to verify; build and run the tests with `xcodebuild`.

## Kotlin

- Prefer `StateFlow` for state, sealed interfaces for variants, `when` over `if-else` chains,
  safe calls and Elvis over null checks. No `!!` in live code.
- Log with Kermit: `Logger.withTag("ServiceClient").d { "Connected to $host" }`. Release
  builds drop Debug/Verbose.
- Wrap async results in `DataState<T>`.
- Bridge members on `KmpHelper` take completions and time out with `withTimeoutOrNull`; return
  `null` for timeout and let RPC failures surface as empty results, matching the rest.
- Test names use backticks but no punctuation Kotlin/Native rejects (`checkTestNames` fails the
  build on `.`, `(`, `,` and friends).
- Run detekt with `CI=true`; without it the local run auto-corrects and hides findings.

## Verification gates

From `docs/CONTRIBUTING.md`, all four before a non-trivial commit:

```bash
JAVA_HOME=/path/to/jdk-21 ./gradlew :composeApp:iosSimulatorArm64Test
CI=true JAVA_HOME=/path/to/jdk-21 ./gradlew detektAll
scripts/build-kotlin-framework.sh debug simulator
xcodebuild test -project iosApp/iosApp.xcodeproj -scheme iosApp \
  -sdk iphonesimulator -destination "id=<simulator-udid>" -configuration Debug
```

Add an unsigned device build (`-sdk iphoneos -destination 'generic/platform=iOS'`) for
anything touching signing, entitlements, or the frameworks. Gate the commit on the result and
read the output — don't chain `git commit` after a test command unconditionally.

Prove a new test can fail: break the code it covers and watch it go red.

## Performance

- Measure in Release, on a device, launched from the home screen — a Debug build under the
  debugger has produced multi-second hangs that did not exist.
- Instruments App Launch and Core Animation are the two templates that matter here.
- Before optimising, read `.claude/perf-and-simplification-plan.md` for what is already
  measured, planned, or deliberately skipped.

## Maintenance

- `architecture.md` when a pattern changes; `dependencies.md` when a library comes or goes;
  `project-structure.md` when a directory does.
- `perf-and-simplification-plan.md` is the running list of improvements; tick items there.
- Feature notes (`settings-screen.md`, `player-overflow-menu-plan.md`, …) are dated; when one
  contradicts the code, the code wins and the note gets a correction.
