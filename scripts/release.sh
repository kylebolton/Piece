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

# Jackett (search indexers) is embedded in the app; re-signed with the release identity when there is one.
./scripts/fetch-jackett.sh

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
# Notarization requires a secure timestamp on every binary; ad-hoc builds can't get one.
TIMESTAMP=--timestamp
[ "$IDENTITY" = "-" ] && TIMESTAMP=--timestamp=none
sign() { codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$@"; }
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
# Nothing is ever sent to Apple unless you ask: set NOTARY_PROFILE, or NOTARIZE=1, explicitly.
# Notarize and staple so Gatekeeper opens the app without warnings. Either of:
#   NOTARY_PROFILE=name        a notarytool keychain profile (xcrun notarytool store-credentials …)
#   NOTARIZE=1                 with ~/.appstoreconnect/publish.env holding the App Store Connect API key vars:
#                              APP_STORE_CONNECT_API_KEY_ID / _ISSUER_ID / _API_KEY_PATH (never printed)
NOTARY_ENV="$HOME/.appstoreconnect/publish.env"
notary_args=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [ "${NOTARIZE:-}" = 1 ] && [ "$IDENTITY" != "-" ] && [ -f "$NOTARY_ENV" ]; then
  set -a; . "$NOTARY_ENV"; set +a
  notary_args=(--key "$APP_STORE_CONNECT_API_KEY_PATH" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
fi
if [ ${#notary_args[@]} -gt 0 ]; then
  xcrun notarytool submit dist/kTorrent.zip "${notary_args[@]}" --wait
  xcrun stapler staple dist/kTorrent.app
  rm dist/kTorrent.zip && ditto -c -k --keepParent dist/kTorrent.app dist/kTorrent.zip
  spctl --assess --type execute -vv dist/kTorrent.app
fi
echo "== dist/kTorrent.app =="
lipo -info dist/kTorrent.app/Contents/MacOS/kTorrent
codesign --verify --deep --strict dist/kTorrent.app && echo "signature ok ($IDENTITY)"
du -sh dist/kTorrent.app dist/kTorrent.zip
