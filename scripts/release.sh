#!/bin/bash
# Builds a universal Release copy of kTorrent into dist/ and zips it.
#
#   scripts/release.sh                         ad-hoc signed (runs on this Mac; others must right-click → Open)
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" scripts/release.sh
#                                              signed for distribution; then notarize with:
#   xcrun notarytool submit dist/kTorrent.zip --keychain-profile <profile> --wait && xcrun stapler staple dist/kTorrent.app
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Vendor/libtorrent/lib/libtorrent-rasterbar.a ] || ./scripts/build-deps.sh
[ -x Vendor/ffmpeg/bin/ffmpeg ] || ./scripts/build-ffmpeg.sh

xcodegen generate >/dev/null
xcodebuild -project kTorrent.xcodeproj -scheme kTorrent -configuration Release -derivedDataPath build \
  -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build \
  | grep -E "error:|\*\* BUILD" || true

APP="build/Build/Products/Release/kTorrent.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }
rm -rf dist && mkdir dist
cp -R "$APP" dist/

IDENTITY="${DEVELOPER_ID:--}"
ENTITLEMENTS=Sources/KTorrent/Resources/kTorrent.entitlements
sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"; }
# Inside-out: Sparkle's helpers, then the framework, then ffmpeg, then the app (which keeps its entitlements).
SPARKLE=dist/kTorrent.app/Contents/Frameworks/Sparkle.framework/Versions/B
if [ -d "$SPARKLE" ]; then
  for nested in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE"/Autoupdate "$SPARKLE"/Updater.app; do
    [ -e "$nested" ] && sign "$nested"
  done
  sign dist/kTorrent.app/Contents/Frameworks/Sparkle.framework
fi
for helper in dist/kTorrent.app/Contents/Helpers/*; do sign "$helper"; done
sign --entitlements "$ENTITLEMENTS" dist/kTorrent.app
[ "$IDENTITY" = "-" ] || codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" dist/kTorrent.app

ditto -c -k --keepParent dist/kTorrent.app dist/kTorrent.zip
echo "== dist/kTorrent.app =="
lipo -info dist/kTorrent.app/Contents/MacOS/kTorrent
codesign --verify --deep --strict dist/kTorrent.app && echo "signature ok ($IDENTITY)"
du -sh dist/kTorrent.app dist/kTorrent.zip
