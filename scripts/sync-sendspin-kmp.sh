#!/usr/bin/env bash
# Copies upstream's `sendspin-kmp` module into this repository, unchanged.
#
# Upstream publishes the module only to GitHub Packages, which needs a token for every
# download. This fork builds it from source instead: the sources, the public API dump and
# the module docs come verbatim from music-assistant/mobile-app; `build.gradle.kts` is the
# fork's own (iOS targets only). The pinned commit is in `sendspin-kmp/UPSTREAM`.
#
# Usage: scripts/sync-sendspin-kmp.sh [<upstream ref>]   (default: upstream/main)
set -euo pipefail

UPSTREAM_URL="https://github.com/music-assistant/mobile-app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/sendspin-kmp"
REF="${1:-upstream/main}"

cd "$ROOT"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch --quiet upstream main
COMMIT="$(git rev-parse --verify "$REF^{commit}")"

# Only what an iOS build needs. androidMain, androidHostTest and the Android consumer check
# stay upstream.
PATHS=(
    sendspin-kmp/src/commonMain
    sendspin-kmp/src/commonTest
    sendspin-kmp/src/iosMain
    sendspin-kmp/api
    sendspin-kmp/README.md
    sendspin-kmp/CHANGELOG.md
)

rm -rf "$MODULE/src" "$MODULE/api" "$MODULE/README.md" "$MODULE/CHANGELOG.md"
git archive "$COMMIT" "${PATHS[@]}" | tar -x -C "$ROOT"

VERSION="$(git show "$COMMIT:gradle.properties" | sed -n 's/^sendspinVersion=//p')"
cat > "$MODULE/UPSTREAM" <<EOF
repository=$UPSTREAM_URL
commit=$COMMIT
sendspinVersion=$VERSION
EOF

echo "sendspin-kmp synced to ${COMMIT:0:10} (sendspinVersion $VERSION)."
echo "Review: git diff --stat -- sendspin-kmp"
