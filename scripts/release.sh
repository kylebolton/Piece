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
for helper in dist/kTorrent.app/Contents/Helpers/*; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$helper"
done
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" dist/kTorrent.app
[ "$IDENTITY" = "-" ] || codesign --force --options runtime --timestamp --deep --sign "$IDENTITY" dist/kTorrent.app

ditto -c -k --keepParent dist/kTorrent.app dist/kTorrent.zip
echo "== dist/kTorrent.app =="
lipo -info dist/kTorrent.app/Contents/MacOS/kTorrent
codesign --verify --deep --strict dist/kTorrent.app && echo "signature ok ($IDENTITY)"
du -sh dist/kTorrent.app dist/kTorrent.zip
