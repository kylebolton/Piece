#!/bin/bash
# Builds static, LGPL-only universal ffmpeg and ffprobe binaries (macOS 14+)
# into Vendor/ffmpeg/bin. They are copied into the app bundle at build time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/src"
MIN_OS="14.0"
JOBS="$(sysctl -n hw.ncpu)"
FFMPEG_VERSION="8.0"

mkdir -p "$SRC" "$VENDOR/ffmpeg/bin"
cd "$SRC"

if [ -f "$VENDOR/ffmpeg/bin/ffmpeg" ] && [ -f "$VENDOR/ffmpeg/bin/ffprobe" ]; then
  echo "ffmpeg already built"
  exit 0
fi

[ -f ffmpeg.tar.xz ] || curl -fL --retry 3 -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

X86ASM="--disable-x86asm"
command -v nasm >/dev/null 2>&1 && X86ASM=""

for arch in arm64 x86_64; do
  rm -rf "ffmpeg-$arch"
  mkdir "ffmpeg-$arch"
  tar xJf ffmpeg.tar.xz -C "ffmpeg-$arch" --strip-components 1
  (
    cd "ffmpeg-$arch"
    EXTRA=""
    if [ "$arch" = "x86_64" ]; then
      EXTRA="--enable-cross-compile --target-os=darwin $X86ASM"
    fi
    # shellcheck disable=SC2086
    ./configure \
      --arch="$arch" \
      --cc="clang -arch $arch" \
      --extra-cflags="-mmacosx-version-min=$MIN_OS" \
      --extra-ldflags="-mmacosx-version-min=$MIN_OS" \
      --disable-autodetect \
      --enable-zlib \
      --enable-videotoolbox \
      --enable-audiotoolbox \
      --disable-doc \
      --disable-debug \
      --disable-ffplay \
      --disable-shared \
      --enable-static \
      --disable-indevs \
      --disable-outdevs \
      $EXTRA
    make -j"$JOBS" ffmpeg ffprobe
  )
done

for bin in ffmpeg ffprobe; do
  lipo -create "ffmpeg-arm64/$bin" "ffmpeg-x86_64/$bin" -output "$VENDOR/ffmpeg/bin/$bin"
  strip -x "$VENDOR/ffmpeg/bin/$bin"
done

echo "== done =="
lipo -info "$VENDOR/ffmpeg/bin/ffmpeg"
"$VENDOR/ffmpeg/bin/ffmpeg" -hide_banner -version | head -1
