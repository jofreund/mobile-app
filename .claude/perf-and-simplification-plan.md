# Performance & Simplification Plan

**Created:** 2026-09-03 from a full review of runtime, architecture and build.
**How to use:** pick the next unchecked item by number. When done, tick it, add the commit hash
and date, and note anything learned. Numbering is global so "do 7" is unambiguous.
Effort: S = under half a day, M = a day, L = several days.

## A. Runtime feel

- [x] **1.** Remove the 50 ms floor on optimistic updates. Overrides feed the debounced
  `combine` in `MainDataSource` (line ~483); apply them after the debounce in the projection
  stage, or replace `debounce` with `conflate()`. (S)
- [x] **2.** Make `PlayerBarItemView` `Equatable` over its flattened value fields, comparing
  `trackItem` by URI, so SwiftUI can skip unchanged `MiniPlayerRow` bodies.
  `PlayerBarStore.swift`. (S)
- [x] **3.** Split the Kotlin projection into a selected-player flow and a lightweight
  player-summary list; make `PlayerBarStore`/`MiniPlayerView` read the summary list and only
  the selected player's full state. (M) **Done in a narrower shape:** after 1 and 2 the player
  rows were cheap; what still scaled badly was every player's *queue* crossing the bridge on
  each real change. Only the selected player carries `queueItems`/`currentItemChapters` now.
  The full summary/selected split was not needed and would have complicated selection.
- [x] **4.** Point `PlayerActivityController` at the selected-player flow only, after 3. (S)
  `MainDataSource.liveActivityState` → `LiveActivitySnapshot` (six fields + `anyPlaying`),
  `distinctUntilChanged`, bridged as `KmpHelper.liveActivityState`.
- [x] **5.** Create `NativeAudioController` and `NowPlayingCoordinator` lazily, only when the
  Sendspin toggle is on. Today `iOSApp.init` builds both unconditionally. (S)
- [ ] **6.** Measure cold launch with the Instruments App Launch template on a Release build
  and record the numbers here before any further init work. (S)
- [ ] **7.** Verify idle cost: Core Animation commits/sec with a scrolling marquee visible, and
  with the expanded player covering the mini player. Target is zero when nothing scrolls. (S)
  **Note 2026-09-03:** unrelated to this item but found while verifying 1+2: the machine is
  now on Xcode 27.0 beta (27A5252f) with iOS 27 simulators, and
  `SVGRasterizerTests.testConcurrentRasterizationsAllSucceed` fails there even in isolation
  (one of four concurrent callers hits `SVGRasterizer.load`'s 3 s bound). All earlier green
  runs were 83 tests on Xcode 26. The other seven rasterizer tests pass, so serial rendering
  works. Needs its own look: either WebKit on the iOS 27 simulator is slower to first paint, or
  the serialization gate has a real hole that the faster old simulator hid.
- [~] **8.** ~~Drop `prettyPrint = true` from `myJson`.~~ **Skipped 2026-09-03:** `LegacyWireGoldenTest` pins the Sendspin wire bytes pretty-printed, so this changes the local player's wire format and breaks the goldens. Not a free win; only worth it with a dedicated compact `Json` for the MA WebSocket. (S)

## B. Architecture: Kotlin → Swift

- [x] **9.** Move `SchemaVersionWarningViewModel` and `AppRootRouter` to Swift; port
  `AppRootRouterTest` to Swift Testing; remove the `androidx.lifecycle-viewmodel`
  dependency. (M)
- [x] **10.** Move UI-only settings (theme, view mode, library filters, home rows, library
  categories, Live Activity visibility) to `UserDefaults`/`@AppStorage`; delete the matching
  `KmpHelper` get/set pairs. (M) **Done for all but library filters:** `LibraryFilters` is also
  the request argument to `fetchLibraryItems` and carries Kotlin enums, so its persistence stays
  in Kotlin; revisit with 13. `AppPreferences.swift` reads Kotlin's keys and encodings, so
  nothing migrates.
- [x] **11.** Delete dead settings residue in `SettingsRepository` (`carTabsConfig`,
  `carPlayableClickActions`, `carBrowsableBulkActions`, both `carDsp*` actions,
  `dynamicColors`, `defaultClickActions`) and `BackgroundUsageGuard` + its Koin binding. (S)
- [x] **12.** Move `DeepLinkBus` and `OAuthCallback` URL parsing to Swift. (S) `DeepLinks.swift`:
  parser, retained-latest queue, OAuth callback parser; Swift passes the return URL into
  `getOAuthUrl`, so it owns the whole callback contract.
- [ ] **13.** Convert `KmpHelper` completion-callback fetchers to `suspend fun` exported as
  Swift `async`, one at a time, keeping `withTimeoutOrNull` inside. First verify that Swift
  task cancellation propagates on Kotlin 2.4. (L, incremental)
- [x] **14.** Replace Koin with a hand-wired graph object (lazy properties). Do after 9–11
  shrink the graph. (M) `AppGraph.kt`; `KtorServiceClient` and `PeerConnectionWrapper` take
  their dependencies as constructor parameters, the WebRTC engine as a `Lazy`.
- [ ] **15.** Optional experiment on a branch: SKIE or Kotlin Swift Export for the bridge.
  Decide on measured link-time cost. (M)

Not planned: rewriting `api/`, `webrtc/` or `player/sendspin` in Swift. Revisit only with a
measurement that points at that code.

## C. Build & repo

- [x] **16.** Build the Kotlin framework outside Xcode and consume it from `iosApp/Frameworks/`
  like WebRTC. Remove the "Compile Kotlin Framework" run-script phase and its hash gate; add a
  script; CI builds the framework in its own step. (M) **Done as a per-configuration framework
  directory, not an XCFramework:** an XCFramework carries one build type and Xcode cannot switch
  a file reference per configuration, whereas `FRAMEWORK_SEARCH_PATHS` already selects on
  `$(CONFIGURATION)/$(PLATFORM_NAME)`. `scripts/build-kotlin-framework.sh [debug|release]
  [simulator|device|all]`. The CI cache job was not split out — the existing Gradle cache
  already covers the Kotlin build, and a separate job would add a workflow for no measured gain.
  **Revised 2026-09-05:** a "Build Kotlin Framework" run-script phase is back, first in the app
  target, calling the script with `--if-changed` (source hash vs. a stamp beside the framework).
  Removing it entirely had traded a ~1 s hash per build for silent stale-framework failures
  ("'KmpHelper' has no member …") whenever Kotlin changed; the script's own JDK lookup removes
  the JAVA_HOME plumbing that motivated the removal. CI still prebuilds and opts the phase out.
- [x] **17.** Add `WebRTC.xcframework` to the app target as Embed & Sign and delete the
  copy/`xattr`/`codesign` script lines. Keep the Gradle test-executable linker flag. (S)
  **Note:** the vendored build's `Info.plist` declares per-slice `dSYMs` directories it does not
  ship, and Xcode refuses an xcframework with a missing declared path (an empty directory does
  not count). `scripts/fetch-webrtc.sh` (new; replaces the duplicated curl blocks in both
  workflows and the docs) downloads it and strips those entries from its `Info.plist`.
- [x] **18.** Delete `lokalise-push.yml` and `lokalise-pull.yml` (dead: their source path no
  longer exists). (S)
- [x] **19.** Gradle hygiene: drop `android.*` properties, `kotlin.native.ignoreDisabledTargets`,
  `TYPESAFE_PROJECT_ACCESSORS`, the `google()` and JetBrains Compose repositories in
  `settings.gradle.kts`, and unused catalog entries (Ktor CIO/Android/Java engines,
  coroutines-swing, kotlin-test-junit). (S) lifecycle-viewmodel already went with 9.
- [x] **20.** Delete repo residue: `.run`, `.fleet`, `.cursor`, `AI-Coding-Handbook`,
  `.well-known`, `scripts/xml_to_xcstrings.py`, `CHANGELOG.md`. Fix the stale bundle id and
  `cacheKind` note in `docs/IOS-BUILD-INSTRUCTIONS.md`. (S)
- [x] **21.** Rewrite `.claude/architecture.md`, `project-structure.md`, `dependencies.md`,
  `guidelines.md` and the `.claude/README.md` index to describe the SwiftUI shell, the
  `KmpHelper` bridge contract, the nil-vs-empty fetch rule and the Kotlin kernel. They are
  imported by `CLAUDE.md` and still describe Compose/Android. (M)

## Suggested order

1 → 2 → 16 → 5 → 21 → 11 → 9 → 10 → 17 → 18 → 19 → 20 → 3 → 4 → 6 → 7 → 8 → 12 → 13 → 14 → 15

## Done log

- 2026-09-04 — leftovers from **19, 20** (branch `claude/gradle-hygiene-repo-residue`): deleted
  `composeApp/lint-baseline.xml` (Android Lint baseline for a manifest that no longer exists),
  pruned the Android entries from `.gitignore`, pointed the PR template at the tasks CI runs,
  dropped the dead `:!androidApp` pathspec in the release-notes step.

- 2026-09-03 — **12, 14** in `24e3210c` (branch `claude/deeplinks-and-di`). Koin is gone from the
  catalog. Remaining: 6, 7 (device measurements), 13 (suspend → async, incremental), 15 (optional
  SKIE/Swift Export experiment).

- 2026-09-03 — **3, 4** in `07668191` (branch `claude/selected-player-projection`). **Trap hit:**
  after the Kotlin framework gains a symbol Swift needs, Xcode may compile against a stale
  precompiled module; do NOT fix that by deleting DerivedData — it wipes the SPM checkouts and
  `swift-opus`'s git submodule then fails to resolve under xcodebuild ("could not lock config
  file …/.git/modules/Sources/Copus/config"). Recovery that worked: `git submodule update --init
  --recursive` inside `DerivedData/iosApp-*/SourcePackages/checkouts/swift-opus`, then build;
  `-resolvePackageDependencies` keeps reporting the error but the build proceeds.

- 2026-09-03 — **18, 20, 19, 10** in `e2bec414`, `cd087bbd`, `621326f5`, `08de994f` (branch
  `claude/settings-and-hygiene`). 19 was proven with `--refresh-dependencies` against Maven
  Central + plugin portal only. 10 also removed `LibraryCategoryConfig.kt` (its Swift port had
  replaced it). `ItemKind`/`ClickContext`/`ItemActionResolver` are still the dead Kotlin trio;
  fold into 13 or a later sweep.

- 2026-09-03 — **21, 11, 9** in `7a602436`, `1ff72267`, `5e938557` (branch `claude/docs-settings-router`,
  stacked on `claude/xcframework-and-lazy-audio`). Root policy is `AppRootPolicy.swift` (pure
  Swift over a `RootSession` snapshot; the test target compiles sources directly and cannot
  import MusicAssistantKit, so the policy must not either), `AppRouter.shared` maps
  `SessionState` and starts from `iOSApp.init`. `ItemKind`/`ClickContext`/`ItemActionResolver`
  are dead but were left (not in 11's list; fold into 20 or 10). Swift suite 146/146, mutation
  check on the splash latch went red as it should.

- 2026-09-03 — **5, 16, 17** in `c43a0032` (branch `claude/xcframework-and-lazy-audio`). Xcode no
  longer runs Gradle; `WebRTC.xcframework` is a plain Embed & Sign reference; the local player's
  Swift half (`LocalPlayerActivation`) comes up only when the Sendspin toggle is on. Docs and
  both CI workflows updated; `scripts/fetch-webrtc.sh` added. Traps found: `/bin/bash` on macOS
  is 3.2 (no `${var^}`), and the WebRTC xcframework's plist declares `dSYMs` it lacks (stripped by the fetch script).

- 2026-09-03 — **1, 2** in `72832aaf` (branch `claude/perf-group-a-low-risk`, merged to main). Also deleted the dead `ui/Timings.kt` (its only consumer was the debounce). Kotlin 476/476, detekt CI clean. Swift suite 125/126: `SVGRasterizerTests.testConcurrentRasterizationsAllSucceed` fails on this machine — see note under 7.
