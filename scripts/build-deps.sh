#!/bin/bash
# Builds OpenSSL and libtorrent-rasterbar as static universal libraries
# (arm64 + x86_64, macOS 14+) into Vendor/. Boost is used headers-only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/src"
MIN_OS="14.0"
JOBS="$(sysctl -n hw.ncpu)"

OPENSSL_VERSION="3.5.0"
BOOST_VERSION="1.88.0"
LIBTORRENT_VERSION="2.0.11"

BOOST_DIR="boost_${BOOST_VERSION//./_}"

mkdir -p "$SRC"
cd "$SRC"

fetch() {
  local url="$1" out="$2"
  [ -f "$out" ] || curl -fL --retry 3 -o "$out" "$url"
}

# ---------------------------------------------------------------- OpenSSL
if [ ! -f "$VENDOR/openssl/lib/libssl.a" ]; then
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" openssl.tar.gz
  for arch in arm64 x86_64; do
    rm -rf "openssl-$arch"
    mkdir "openssl-$arch"
    tar xzf openssl.tar.gz -C "openssl-$arch" --strip-components 1
    (
      cd "openssl-$arch"
      ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs no-apps \
        --prefix="$SRC/openssl-install-$arch" "-mmacosx-version-min=$MIN_OS"
      make -j"$JOBS"
      make install_sw
    )
  done
  mkdir -p "$VENDOR/openssl/lib"
  cp -R "$SRC/openssl-install-arm64/include" "$VENDOR/openssl/"
  for lib in libssl.a libcrypto.a; do
    lipo -create "$SRC/openssl-install-arm64/lib/$lib" "$SRC/openssl-install-x86_64/lib/$lib" \
      -output "$VENDOR/openssl/lib/$lib"
  done
fi

# ---------------------------------------------------------------- Boost (headers)
if [ ! -d "$VENDOR/boost/include/boost" ]; then
  fetch "https://archives.boost.io/release/$BOOST_VERSION/source/$BOOST_DIR.tar.bz2" boost.tar.bz2
  rm -rf "$BOOST_DIR"
  tar xjf boost.tar.bz2 "$BOOST_DIR/boost"
  mkdir -p "$VENDOR/boost/include"
  mv "$BOOST_DIR/boost" "$VENDOR/boost/include/boost"
fi

# ---------------------------------------------------------------- libtorrent
if [ ! -f "$VENDOR/libtorrent/lib/libtorrent-rasterbar.a" ]; then
  fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" libtorrent.tar.gz
  rm -rf libtorrent
  mkdir libtorrent
  tar xzf libtorrent.tar.gz -C libtorrent --strip-components 1
  cmake -S libtorrent -B libtorrent/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS" \
    -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF \
    -Ddeprecated-functions=OFF \
    -DBoost_INCLUDE_DIR="$VENDOR/boost/include" \
    -DOPENSSL_ROOT_DIR="$VENDOR/openssl" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DCMAKE_INSTALL_PREFIX="$VENDOR/libtorrent"
  cmake --build libtorrent/build -j"$JOBS"
  cmake --install libtorrent/build
fi

echo "== done =="
lipo -info "$VENDOR/openssl/lib/libcrypto.a" "$VENDOR/libtorrent/lib/libtorrent-rasterbar.a"
