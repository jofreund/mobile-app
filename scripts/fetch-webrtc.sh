#!/usr/bin/env bash
#
# Fetches the vendored WebRTC.xcframework into iosApp/Frameworks/ (gitignored) and makes it
# something Xcode will accept as a framework reference. Idempotent: an existing download is
# kept, only the fix-up below is re-applied.
#
# Patched M125 build from teancom/webrtc — the same binary upstream ships (125.6422.02) with
# the DcSctpTransport receive_buffer fix from webrtc-sdk/webrtc#234 backported. Replace with a
# stock webrtc-sdk/Specs release once the fix lands there. TAG is the one place the version
# lives; the CI cache key in .github/workflows names it too.
#
set -euo pipefail

TAG="m125-cow-bloat-fix.1"
URL="https://github.com/teancom/webrtc/releases/download/$TAG/WebRTC.xcframework.$TAG.zip"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/iosApp/Frameworks"
XCF="$DEST/WebRTC.xcframework"

if [ ! -d "$XCF/ios-arm64/WebRTC.framework" ]; then
  echo "▸ downloading WebRTC.xcframework $TAG"
  TMP="$(mktemp -d)"
  curl -L --fail "$URL" -o "$TMP/webrtc.zip"
  mkdir -p "$DEST"
  unzip -q "$TMP/webrtc.zip" -d "$DEST"
  rm -rf "$TMP"
  test -d "$XCF/ios-arm64/WebRTC.framework" || { echo "unexpected zip layout: no ios-arm64/WebRTC.framework" >&2; exit 1; }
fi

# The release ships without dSYMs, but each slice's entry in Info.plist still declares
# `DebugSymbolsPath = dSYMs`. Xcode refuses to process an xcframework whose declared paths are
# missing ("Missing path ... from XCFramework") — an empty directory does not satisfy it — so
# drop the declarations that point at nothing. The bundle is unsigned, so editing its plist is
# safe. If a future release does ship dSYMs, the entries are left alone.
python3 - "$XCF" <<'PY'
import os, plistlib, sys
xcf = sys.argv[1]
plist = os.path.join(xcf, "Info.plist")
with open(plist, "rb") as f:
    info = plistlib.load(f)
changed = False
for lib in info.get("AvailableLibraries", []):
    rel = lib.get("DebugSymbolsPath")
    if rel and not os.path.isdir(os.path.join(xcf, lib["LibraryIdentifier"], rel)):
        del lib["DebugSymbolsPath"]
        changed = True
if changed:
    with open(plist, "wb") as f:
        plistlib.dump(info, f)
PY

echo "▸ $XCF"
ls "$XCF"
