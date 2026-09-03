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
- [ ] **3.** Split the Kotlin projection into a selected-player flow and a lightweight
  player-summary list; make `PlayerBarStore`/`MiniPlayerView` read the summary list and only
  the selected player's full state. (M)
- [ ] **4.** Point `PlayerActivityController` at the selected-player flow only, after 3. (S)
- [ ] **5.** Create `NativeAudioController` and `NowPlayingCoordinator` lazily, only when the
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

- [ ] **9.** Move `SchemaVersionWarningViewModel` and `AppRootRouter` to Swift; port
  `AppRootRouterTest` to Swift Testing; remove the `androidx.lifecycle-viewmodel`
  dependency. (M)
- [ ] **10.** Move UI-only settings (theme, view mode, library filters, home rows, library
  categories, Live Activity visibility) to `UserDefaults`/`@AppStorage`; delete the matching
  `KmpHelper` get/set pairs. (M)
- [ ] **11.** Delete dead settings residue in `SettingsRepository` (`carTabsConfig`,
  `carPlayableClickActions`, `carBrowsableBulkActions`, both `carDsp*` actions,
  `dynamicColors`, `defaultClickActions`) and `BackgroundUsageGuard` + its Koin binding. (S)
- [ ] **12.** Move `DeepLinkBus` and `OAuthCallback` URL parsing to Swift. (S)
- [ ] **13.** Convert `KmpHelper` completion-callback fetchers to `suspend fun` exported as
  Swift `async`, one at a time, keeping `withTimeoutOrNull` inside. First verify that Swift
  task cancellation propagates on Kotlin 2.4. (L, incremental)
- [ ] **14.** Replace Koin with a hand-wired graph object (lazy properties). Do after 9–11
  shrink the graph. (M)
- [ ] **15.** Optional experiment on a branch: SKIE or Kotlin Swift Export for the bridge.
  Decide on measured link-time cost. (M)

Not planned: rewriting `api/`, `webrtc/` or `player/sendspin` in Swift. Revisit only with a
measurement that points at that code.

## C. Build & repo

- [ ] **16.** Build `MusicAssistantKit.xcframework` via Gradle and consume it from
  `iosApp/Frameworks/` like WebRTC. Remove the "Compile Kotlin Framework" run-script phase and
  its hash gate; add a `make kotlin` (or script) target; give CI a separate framework job cached
  on the hash of `composeApp/src` + Gradle files. (M)
- [ ] **17.** Add `WebRTC.xcframework` to the app target as Embed & Sign and delete the
  copy/`xattr`/`codesign` script lines. Keep the Gradle test-executable linker flag. (S)
- [ ] **18.** Delete `lokalise-push.yml` and `lokalise-pull.yml` (dead: their source path no
  longer exists). (S)
- [ ] **19.** Gradle hygiene: drop `android.*` properties, `kotlin.native.ignoreDisabledTargets`,
  `TYPESAFE_PROJECT_ACCESSORS`, the `google()` and JetBrains Compose repositories in
  `settings.gradle.kts`, and unused catalog entries (Ktor CIO/Android/Java engines,
  coroutines-swing, kotlin-test-junit; lifecycle-viewmodel after 9). (S)
- [ ] **20.** Delete repo residue: `.run`, `.fleet`, `.cursor`, `AI-Coding-Handbook`,
  `.well-known`, `scripts/xml_to_xcstrings.py`, `CHANGELOG.md`. Fix the stale bundle id and
  `cacheKind` note in `docs/IOS-BUILD-INSTRUCTIONS.md`. (S)
- [ ] **21.** Rewrite `.claude/architecture.md`, `project-structure.md`, `dependencies.md`,
  `guidelines.md` and the `.claude/README.md` index to describe the SwiftUI shell, the
  `KmpHelper` bridge contract, the nil-vs-empty fetch rule and the Kotlin kernel. They are
  imported by `CLAUDE.md` and still describe Compose/Android. (M)

## Suggested order

1 → 2 → 16 → 5 → 21 → 11 → 9 → 10 → 17 → 18 → 19 → 20 → 3 → 4 → 6 → 7 → 8 → 12 → 13 → 14 → 15

## Done log

- 2026-09-03 — **1, 2** in `72832aaf` (branch `claude/perf-group-a-low-risk`, merged to main). Also deleted the dead `ui/Timings.kt` (its only consumer was the debounce). Kotlin 476/476, detekt CI clean. Swift suite 125/126: `SVGRasterizerTests.testConcurrentRasterizationsAllSucceed` fails on this machine — see note under 7.
