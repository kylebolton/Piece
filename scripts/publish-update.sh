#!/bin/bash
# Publishes dist/kTorrent.zip as an auto-update:
#   1. bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml
#   2. scripts/release.sh
#   3. scripts/publish-update.sh        (this script)
#
# Signs the archive with the EdDSA key in your login Keychain (created once by scripts/setup-updates.sh),
# rebuilds appcast.xml, and creates the GitHub release the appcast points at. Commit and push appcast.xml
# afterwards: installed copies read it from the main branch.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP=dist/kTorrent.zip
[ -f "$ZIP" ] || { echo "Run scripts/release.sh first."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/kTorrent.app/Contents/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" dist/kTorrent.app/Contents/Info.plist)
REPO=$(git config --get remote.origin.url | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
BIN=$(find build/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)
[ -n "$BIN" ] || { echo "Sparkle tools not found; build the project once first."; exit 1; }

# The feed only ever needs the newest version (each release keeps its own zip on GitHub), so rebuild it
# from scratch: older entries would be rewritten to this release's download URL.
rm -rf .updates appcast.xml && mkdir -p .updates
cp "$ZIP" ".updates/kTorrent-$VERSION.zip"
"$BIN/generate_appcast" .updates --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  -o appcast.xml
echo "== appcast.xml updated for $VERSION (build $BUILD) =="

if command -v gh >/dev/null; then
  gh release create "v$VERSION" ".updates/kTorrent-$VERSION.zip" --repo "$REPO" \
    --title "kTorrent $VERSION" --notes "kTorrent $VERSION" || echo "Release v$VERSION already exists or failed; upload the zip by hand."
fi
echo "Now commit and push appcast.xml."
