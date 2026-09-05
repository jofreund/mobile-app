#!/usr/bin/env bash
#
# Builds the Kotlin framework (MusicAssistantKit) and drops it where the Xcode project looks:
#
#   iosApp/Frameworks/Kotlin/<Debug|Release>/<iphonesimulator|iphoneos>/MusicAssistantKit.framework
#
# which is what the app target's FRAMEWORK_SEARCH_PATHS resolves through
# $(CONFIGURATION)/$(PLATFORM_NAME). The output directory is gitignored (iosApp/Frameworks/),
# like the vendored WebRTC.
#
#   scripts/build-kotlin-framework.sh                  # debug, simulator + device
#   scripts/build-kotlin-framework.sh debug simulator  # the fast inner loop
#   scripts/build-kotlin-framework.sh release device   # what an archive needs
#
# The app target's "Build Kotlin Framework" run-script phase calls this with a third argument,
# `--if-changed`, for the configuration and platform being built: the framework is rebuilt
# only when a hash of the Kotlin sources and Gradle files differs from the stamp written next
# to the last build, so a Swift-only build pays under a second and never links a stale
# framework. CI builds the framework in its own step and passes KOTLIN_FRAMEWORK_PREBUILT=YES
# to xcodebuild, which makes the phase exit before calling this script.
#
set -euo pipefail

BUILD_TYPE="${1:-debug}"
PLATFORMS="${2:-all}"
IF_CHANGED="${3:-}"
case "$IF_CHANGED" in
  ""|--if-changed) ;;
  *) echo "usage: $0 [debug|release] [simulator|device|all] [--if-changed]" >&2; exit 2 ;;
esac

case "$BUILD_TYPE" in
  debug)   CONFIGURATION=Debug;   GRADLE_TYPE=Debug;   OUT_TYPE=debugFramework ;;
  release) CONFIGURATION=Release; GRADLE_TYPE=Release; OUT_TYPE=releaseFramework ;;
  *) echo "usage: $0 [debug|release] [simulator|device|all]" >&2; exit 2 ;;
esac

case "$PLATFORMS" in
  simulator) TARGETS=(iosSimulatorArm64) ;;
  device)    TARGETS=(iosArm64) ;;
  all)       TARGETS=(iosSimulatorArm64 iosArm64) ;;
  *) echo "usage: $0 [debug|release] [simulator|device|all]" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Everything that can change the framework's contents or its exported header. Sorted so the
# hash is stable across filesystems; the script itself is included so a change to how the
# framework is built also rebuilds it.
source_hash() {
  {
    find composeApp/src -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum
    for f in build.gradle.kts composeApp/build.gradle.kts gradle.properties settings.gradle.kts \
             gradle/libs.versions.toml gradle/gradle-daemon-jvm.properties \
             gradle/wrapper/gradle-wrapper.properties scripts/build-kotlin-framework.sh; do
      if [ -f "$f" ]; then shasum "$f"; fi
    done
  } | shasum | awk '{print $1}'
}

dst_dir() {
  case "$1" in
    iosSimulatorArm64) echo "iosApp/Frameworks/Kotlin/$CONFIGURATION/iphonesimulator" ;;
    iosArm64)          echo "iosApp/Frameworks/Kotlin/$CONFIGURATION/iphoneos" ;;
  esac
}

HASH="$(source_hash)"
if [ "$IF_CHANGED" = "--if-changed" ]; then
  current=1
  for target in "${TARGETS[@]}"; do
    dir="$(dst_dir "$target")"
    if [ ! -d "$dir/MusicAssistantKit.framework" ] || [ "$(cat "$dir/.source-hash" 2>/dev/null)" != "$HASH" ]; then
      current=0
    fi
  done
  if [ "$current" = 1 ]; then
    echo "▸ MusicAssistantKit ($BUILD_TYPE, $PLATFORMS) is current — Kotlin sources and Gradle files unchanged"
    exit 0
  fi
fi

# Gradle 9 / Kotlin 2.4 need JDK 21. Honour an explicit JAVA_HOME, otherwise ask macOS for it.
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
  export JAVA_HOME
fi
if [ -z "${JAVA_HOME:-}" ]; then
  echo "JAVA_HOME is unset and no JDK 21 was found (/usr/libexec/java_home -v 21)." >&2
  exit 1
fi

# /bin/bash on macOS is 3.2, so no ${var^} — map the target names by hand.
GRADLE_TASKS=()
for target in "${TARGETS[@]}"; do
  case "$target" in
    iosSimulatorArm64) GRADLE_TASKS+=(":composeApp:link${GRADLE_TYPE}FrameworkIosSimulatorArm64") ;;
    iosArm64)          GRADLE_TASKS+=(":composeApp:link${GRADLE_TYPE}FrameworkIosArm64") ;;
  esac
done

echo "▸ ./gradlew ${GRADLE_TASKS[*]}"
./gradlew "${GRADLE_TASKS[@]}"

for target in "${TARGETS[@]}"; do
  SRC="composeApp/build/bin/$target/$OUT_TYPE/MusicAssistantKit.framework"
  DST_DIR="$(dst_dir "$target")"
  test -d "$SRC" || { echo "expected Gradle output missing: $SRC" >&2; exit 1; }
  mkdir -p "$DST_DIR"
  rsync -a --delete "$SRC/" "$DST_DIR/MusicAssistantKit.framework/"
  # The stamp the --if-changed gate compares against; written last so an interrupted copy
  # never passes as current.
  echo "$HASH" > "$DST_DIR/.source-hash"
  echo "▸ $DST_DIR/MusicAssistantKit.framework"
done
