#!/bin/bash
# Debug build for the current architecture. Prints only errors and the result.
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project kTorrent.xcodeproj -scheme kTorrent -configuration Debug -derivedDataPath build \
  -destination "platform=macOS,arch=$(uname -m)" ONLY_ACTIVE_ARCH=YES "${@:-build}" 2>&1 \
  | grep -E "^/.*(error|warning): |error: |\*\* (BUILD|TEST)|Executed [0-9]+ tests|ld: |Undefined symbol" \
  | grep -v "Vendor/" | sort -u | head -${MAX_LINES:-60}
