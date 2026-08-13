#!/usr/bin/env bash
# Download the exact artifacts under test straight from Maven Central.
# No Maven involved, so the matrix is hermetic and reproducible.
set -euo pipefail
cd "$(dirname "$0")"

CENTRAL=https://repo1.maven.org/maven2/io/netty
LIBS=libs
mkdir -p "$LIBS"

# Native artifacts: <artifact>:<version> x {linux-x86_64, linux-aarch_64}
NATIVE_EPOLL_VERSIONS="4.2.12.Final 4.2.17.Final"
NATIVE_TCNATIVE_VERSIONS="2.0.65.Final 2.0.73.Final 2.0.75.Final 2.0.81.Final"
CLASSIFIERS="linux-x86_64 linux-aarch_64"

# Plain jars needed to exercise the real Netty API (Level B). Fetched for every netty
# version under test so the Java classes always match the .so they load.
NETTY_CP_VERSIONS="$NATIVE_EPOLL_VERSIONS"
NETTY_CP_ARTIFACTS="netty-common netty-buffer netty-transport netty-resolver netty-codec \
netty-codec-base netty-handler netty-transport-classes-epoll netty-transport-native-unix-common \
netty-pkitesting"

get() { # url dest
  if [ -s "$2" ]; then echo "  cached  $(basename "$2")"; return 0; fi
  if curl -fsSL "$1" -o "$2.tmp"; then
    mv "$2.tmp" "$2"; echo "  ok      $(basename "$2")"
  else
    rm -f "$2.tmp"; echo "  MISSING $(basename "$2")  <- $1" >&2; return 1
  fi
}

echo "== native: netty-transport-native-epoll"
for v in $NATIVE_EPOLL_VERSIONS; do
  for c in $CLASSIFIERS; do
    get "$CENTRAL/netty-transport-native-epoll/$v/netty-transport-native-epoll-$v-$c.jar" \
        "$LIBS/netty-transport-native-epoll-$v-$c.jar" || true
  done
done

echo "== native: netty-tcnative-boringssl-static"
for v in $NATIVE_TCNATIVE_VERSIONS; do
  for c in $CLASSIFIERS; do
    get "$CENTRAL/netty-tcnative-boringssl-static/$v/netty-tcnative-boringssl-static-$v-$c.jar" \
        "$LIBS/netty-tcnative-boringssl-static-$v-$c.jar" || true
  done
done

echo "== classpath jars"
for v in $NETTY_CP_VERSIONS; do
  for a in $NETTY_CP_ARTIFACTS; do
    get "$CENTRAL/$a/$v/$a-$v.jar" "$LIBS/$a-$v.jar" || true
  done
done
# tcnative-classes must match the tcnative native lib version at runtime; grab each.
for v in $NATIVE_TCNATIVE_VERSIONS; do
  get "$CENTRAL/netty-tcnative-classes/$v/netty-tcnative-classes-$v.jar" \
      "$LIBS/netty-tcnative-classes-$v.jar" || true
done

# ---- positive control: async-profiler ships ONE binary that works on glibc AND musl ----
echo "== positive control: async-profiler"
AP_VERSION="${AP_VERSION:-4.1}"
for arch in x64 arm64; do
  tgz="$LIBS/async-profiler-$AP_VERSION-linux-$arch.tar.gz"
  url="https://github.com/async-profiler/async-profiler/releases/download/v$AP_VERSION/async-profiler-$AP_VERSION-linux-$arch.tar.gz"
  if get "$url" "$tgz"; then
    so_arch=$([ "$arch" = x64 ] && echo x86_64 || echo aarch_64)
    tar -xzf "$tgz" -C "$LIBS" --strip-components=2 --wildcards '*/lib/libasyncProfiler.so' 2>/dev/null \
      && mv "$LIBS/libasyncProfiler.so" "$LIBS/libasyncProfiler-$so_arch.so" \
      && echo "  ok      libasyncProfiler-$so_arch.so"
  fi
done

echo
echo "Done. $(find "$LIBS" -name '*.jar' | wc -l | tr -d ' ') jars, $(find "$LIBS" -name '*.so' | wc -l | tr -d ' ') control .so in $LIBS/"
