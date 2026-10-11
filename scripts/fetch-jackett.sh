#!/bin/bash
# Fetches the pinned Jackett release for both Mac architectures into Vendor/jackett/, checks each against
# its SHA-256, signs every Mach-O file inside when DEVELOPER_ID is set (needed for notarization), and repacks
# them as Jackett-<version>-<arch>.tar.gz. The app build embeds these, and JackettManager unpacks the one for
# the Mac it runs on. Jackett is GPL-2.0 and is included unmodified: https://github.com/Jackett/Jackett
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v0.24.2816
SHA_ARM64=f677e70ad76af0b9022478f1fcb37298b66a356cf9fbbdcf2c79c3941280fee5
SHA_X86_64=4a44d0a3c86b8f0f7d3ab9c3b98534acbb2940d3d3c3c84a3cfb5aac5e87ceb9
IDENTITY="${DEVELOPER_ID:--}"

OUT=Vendor/jackett
mkdir -p "$OUT/download"

pack() { # arch asset sha
  local arch=$1 asset=$2 sha=$3
  local raw="$OUT/download/$VERSION-$asset"
  [ -f "$raw" ] || curl -fL --retry 3 -o "$raw" "https://github.com/Jackett/Jackett/releases/download/$VERSION/$asset"
  [ "$(shasum -a 256 "$raw" | cut -d' ' -f1)" = "$sha" ] || { echo "checksum mismatch for $asset"; rm -f "$raw"; exit 1; }

  local work; work=$(mktemp -d)
  tar -xzf "$raw" -C "$work"
  if [ "$IDENTITY" != "-" ]; then
    echo "signing $arch with $IDENTITY"
    find "$work/Jackett" -type f | while read -r file; do
      if file -b "$file" | grep -q "Mach-O"; then
        extra=()
        [ "$(basename "$file")" = "jackett" ] && extra=(--entitlements scripts/jackett.entitlements)
        codesign --force --options runtime --timestamp ${extra[@]+"${extra[@]}"} --sign "$IDENTITY" "$file"
      fi
    done
  fi
  tar -czf "$OUT/Jackett-$VERSION-$arch.tar.gz" -C "$work" Jackett
  rm -rf "$work"
  echo "$OUT/Jackett-$VERSION-$arch.tar.gz  $(du -h "$OUT/Jackett-$VERSION-$arch.tar.gz" | cut -f1)"
}

rm -f "$OUT"/Jackett-*.tar.gz
pack arm64 Jackett.Binaries.macOSARM64.tar.gz "$SHA_ARM64"
pack x86_64 Jackett.Binaries.macOS.tar.gz "$SHA_X86_64"
