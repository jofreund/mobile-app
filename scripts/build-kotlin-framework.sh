#!/usr/bin/env bash
#
# Builds the Kotlin framework (MusicAssistantKit) and drops it where the Xcode project looks:
#
#   iosApp/Frameworks/Kotlin/<Debug|Release>/<iphonesimulator|iphoneos>/MusicAssistantKit.framework
#
# which is what the app target's FRAMEWORK_SEARCH_PATHS resolves through
# $(CONFIGURATION)/$(PLATFORM_NAME). Xcode itself never runs Gradle any more — an Xcode build
# is pure Swift and takes seconds; run this when the Kotlin sources or Gradle files change.
# The output directory is gitignored (iosApp/Frameworks/), like the vendored WebRTC.
#
#   scripts/build-kotlin-framework.sh                  # debug, simulator + device
#   scripts/build-kotlin-framework.sh debug simulator  # the fast inner loop
#   scripts/build-kotlin-framework.sh release device   # what an archive needs
#
set -euo pipefail

BUILD_TYPE="${1:-debug}"
PLATFORMS="${2:-all}"

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
  case "$target" in
    iosSimulatorArm64) PLATFORM_NAME=iphonesimulator ;;
    iosArm64)          PLATFORM_NAME=iphoneos ;;
  esac
  SRC="composeApp/build/bin/$target/$OUT_TYPE/MusicAssistantKit.framework"
  DST_DIR="iosApp/Frameworks/Kotlin/$CONFIGURATION/$PLATFORM_NAME"
  test -d "$SRC" || { echo "expected Gradle output missing: $SRC" >&2; exit 1; }
  mkdir -p "$DST_DIR"
  rsync -a --delete "$SRC/" "$DST_DIR/MusicAssistantKit.framework/"
  echo "▸ $DST_DIR/MusicAssistantKit.framework"
done
