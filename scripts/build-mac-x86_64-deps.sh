#!/bin/bash
# Build x86_64 OpenSSL and APR on an Apple Silicon Mac, so openssl-dynamic can be cross-compiled
# for osx-x86_64 there instead of on an Intel runner.
#
# Homebrew on Apple Silicon installs only arm64 into /opt/homebrew, and the x86_64 prefixes the
# mac-x86_64 profile expects (/usr/local/opt/...) do not exist. Neither does a second Rosetta
# Homebrew on the GitHub macos-15 image. So the two shared libraries openssl-dynamic links against
# have to come from source.
#
# Cross-compiling needs no Rosetta: the macOS SDK ships universal .tbd stubs, so clang can target
# x86_64 from an arm64 host. Rosetta is only needed to *run* x86_64 binaries.
#
# usage: build-mac-x86_64-deps.sh [prefix]
#   prefix defaults to <repo>/.mac-x86_64-deps
#
# Deliberately NOT under target/: the reactor's clean would delete it, and these take several
# minutes to build.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
PREFIX="${1:-$HERE/.mac-x86_64-deps}"
WORK="$PREFIX/src"
TARGET_TRIPLE=x86_64-apple-macos10.12
JOBS=$(sysctl -n hw.ncpu)

# Track the versions the build actually uses rather than hardcoding a second copy.
pom_prop() {
  sed -n "s|.*<$1>\(.*\)</$1>.*|\1|p" "$HERE/pom.xml" | head -1
}
OPENSSL_MINOR=$(pom_prop opensslMinorVersion)
OPENSSL_PATCH=$(pom_prop opensslPatchVersion)
OPENSSL_VERSION="$OPENSSL_MINOR.$OPENSSL_PATCH"
APR_VERSION=$(pom_prop aprVersion)

echo "== building x86_64 deps into $PREFIX"
echo "   openssl $OPENSSL_VERSION, apr $APR_VERSION, -j$JOBS"

mkdir -p "$WORK"

# ---------------------------------------------------------------------------- OpenSSL
if [ -f "$PREFIX/lib/libssl.dylib" ]; then
  echo "== openssl already built, skipping"
else
  cd "$WORK"
  [ -f "openssl-$OPENSSL_VERSION.tar.gz" ] || \
    curl -sSfLO "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
  rm -rf "openssl-$OPENSSL_VERSION"
  tar xzf "openssl-$OPENSSL_VERSION.tar.gz"
  cd "openssl-$OPENSSL_VERSION"
  # darwin64-x86_64-cc is the same target openssl-static/pom.xml uses for the intel build.
  # no-apps: only libssl/libcrypto are needed here.
  ./Configure darwin64-x86_64-cc --prefix="$PREFIX" --libdir=lib shared no-apps
  make -j"$JOBS" build_sw
  make install_sw
fi

# ---------------------------------------------------------------------------- APR
if [ -f "$PREFIX/lib/libapr-1.dylib" ]; then
  echo "== apr already built, skipping"
else
  cd "$WORK"
  [ -f "apr-$APR_VERSION.tar.gz" ] || \
    curl -sSfLO "https://archive.apache.org/dist/apr/apr-$APR_VERSION.tar.gz"
  rm -rf "apr-$APR_VERSION"
  tar xzf "apr-$APR_VERSION.tar.gz"
  cd "apr-$APR_VERSION"
  # The ac_cv_* overrides are the same ones the linux/mac cross build in pom.xml already needs:
  # configure cannot run its test binaries when they are built for a foreign architecture.
  ./configure --host=x86_64-apple-darwin --prefix="$PREFIX" \
    CFLAGS="-O3 -fno-omit-frame-pointer -fPIC -target $TARGET_TRIPLE" \
    LDFLAGS="-arch x86_64" \
    ac_cv_have_decl_sys_siglist=no \
    ac_cv_file__dev_zero=yes \
    apr_cv_process_shared_works=yes \
    apr_cv_mutex_robust_shared=no \
    apr_cv_tcp_nodelay_with_cork=yes
  # APR's make runs gen_test_char, which cannot execute when cross-built. Build a native copy of
  # just that tool and generate the header by hand, exactly as pom.xml does for the linux cross.
  make -j"$JOBS" || true
  cc -Wall -O2 -DCROSS_COMPILE tools/gen_test_char.c -o tools/gen_test_char
  ./tools/gen_test_char > include/private/apr_escape_test_char.h
  make -j"$JOBS"
  make install
fi

# ------------------------------------------------------------------- install names
# The linker records a dependency using the dylib's own LC_ID_DYLIB, so left alone these libraries
# would bake $PREFIX into the artifact and make it unloadable anywhere else. Point the ids at the
# Homebrew locations the released osx-x86_64 artifact already records, so a cross-built library has
# the same dependency paths as one built natively on an Intel machine.
#
# Note the released 2.0.81 artifact references openssl@3, while the poms ask for
# openssl@${openssl.lib.version} (3.6). Reproduce what actually ships.
SSL_ID=/usr/local/opt/openssl@3/lib
APR_ID=/usr/local/opt/apr/lib

echo "== rewriting install names"
install_name_tool -id "$SSL_ID/libcrypto.3.dylib" "$PREFIX/lib/libcrypto.3.dylib"
install_name_tool -id "$SSL_ID/libssl.3.dylib"    "$PREFIX/lib/libssl.3.dylib"
install_name_tool -id "$APR_ID/libapr-1.0.dylib"  "$PREFIX/lib/libapr-1.0.dylib"
# libssl links libcrypto; keep that edge consistent too.
install_name_tool -change "$PREFIX/lib/libcrypto.3.dylib" "$SSL_ID/libcrypto.3.dylib" \
  "$PREFIX/lib/libssl.3.dylib" 2>/dev/null || true

echo "== done"
for lib in libssl.3.dylib libcrypto.3.dylib libapr-1.0.dylib; do
  if [ -f "$PREFIX/lib/$lib" ]; then
    printf '   %-20s %s\n' "$lib" "$(lipo -archs "$PREFIX/lib/$lib" 2>/dev/null)"
  fi
done
echo "   prefix: $PREFIX"
