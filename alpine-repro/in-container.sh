#!/usr/bin/env bash
# Runs the whole per-(arch,variant) sweep inside one Alpine container.
# usage: in-container.sh <variant-label>
set -uo pipefail
cd /w

VARIANT="${1:-unknown}"
MACHINE="$(uname -m)"
case "$MACHINE" in
  aarch64) CLS=linux-aarch_64; SOARCH=aarch_64 ;;
  x86_64)  CLS=linux-x86_64;   SOARCH=x86_64 ;;
  *) echo "unsupported arch $MACHINE" >&2; exit 1 ;;
esac

# Overridable so a locally-built version can be tested without editing this file, e.g.
#   TCNATIVE_VERSIONS=2.0.76.Final-SNAPSHOT ./run-matrix.sh --arch arm64
# The jars must follow the released naming convention in libs/:
#   netty-tcnative-boringssl-static-<version>-<classifier>.jar  and
#   netty-tcnative-classes-<version>.jar
EPOLL_VERSIONS="${EPOLL_VERSIONS:-4.2.12.Final 4.2.17.Final}"
TCNATIVE_VERSIONS="${TCNATIVE_VERSIONS:-2.0.65.Final 2.0.73.Final 2.0.75.Final 2.0.81.Final}"
CORE_ARTIFACTS="netty-common netty-buffer netty-transport netty-resolver netty-codec \
netty-codec-base netty-handler netty-transport-classes-epoll netty-transport-native-unix-common \
netty-pkitesting"
# netty version whose core jars back the OpenSsl (tcnative) checks
OPENSSL_NETTY_VERSION=4.2.12.Final

echo "================================================================"
echo "ARCH=$MACHINE  VARIANT=$VARIANT  CLASSIFIER=$CLS"
echo "musl:      $(apk info -v musl 2>/dev/null | head -1)"
echo "compat:    $(apk info 2>/dev/null | grep -Ex 'libc6-compat|gcompat|libstdc\+\+|libgcc' | sort | tr '\n' ' ')"
echo "java:      $(java -version 2>&1 | head -1)"
echo "================================================================"

mkdir -p out
javac -d out src/AlpineNativeLoadTest.java || { echo "javac failed" >&2; exit 1; }

# tcnative >=2.0.73 on aarch64 does not fail cleanly -- libgcc's init_have_lse_atomics
# constructor calls the unresolved __getauxval and SIGSEGVs the JVM. Keep the 400MB core
# dumps and hs_err files out of the mounted work tree, and record the crash as a FAIL.
ulimit -c 0 2>/dev/null || true
JVM_SAFE="-XX:-CreateCoredumpOnCrash -XX:ErrorFile=/tmp/hs_err_%p.log"

# Runs one check; if the JVM dies without printing a RESULT line, synthesise one so a
# hard crash is never silently missing from the matrix.
run_check() { # label level <java args...>
  local label="$1" level="$2"; shift 2
  local out rc
  # PRELOAD is passed via the environment rather than a `VAR=x func` prefix, which bash
  # does not reliably export into a shell function's child processes.
  out=$(LD_PRELOAD="${PRELOAD:-}" java $JVM_SAFE "$@" 2>&1); rc=$?
  if printf '%s\n' "$out" | grep -q '^RESULT'; then
    printf '%s\n' "$out" | grep '^RESULT'
  else
    local frame
    frame=$(printf '%s\n' "$out" | sed -n 's/^# C  \[\(.*\)\].*/\1/p' | head -1)
    local sig
    sig=$(printf '%s\n' "$out" | sed -n 's/.*A fatal error.*/JVM-CRASH/p' | head -1)
    printf 'RESULT\t%s\t%s\tFAIL\t%s exit=%s %s\n' \
      "$label" "$level" "${sig:-no-output}" "$rc" "${frame:+in $frame}"
  fi
  printf '%s\n' "$out" | grep -E '^#  (SIGSEGV|SIGBUS|SIGILL)|^# C  \[' | sed 's/^/   crash| /'
}

core_cp() { # version -> core jars for that netty version
  local v="$1" cp=""
  for a in $CORE_ARTIFACTS; do cp="$cp:libs/$a-$v.jar"; done
  echo "${cp#:}"
}

# ---------------------------------------------------------------- ELF scan + Level A
for v in $EPOLL_VERSIONS; do
  jar="libs/netty-transport-native-epoll-$v-$CLS.jar"
  [ -f "$jar" ] || continue
  rm -rf /tmp/x && mkdir -p /tmp/x && unzip -qo "$jar" -d /tmp/x
  so=$(find /tmp/x -name '*.so' | head -1)
  ./elf-scan.sh "$so" "epoll-$v-$SOARCH"
  # JNI_OnLoad registers natives against these classes, so they must be on the classpath --
  # otherwise a NoClassDefFoundError masks the real (or absent) linking error.
  run_check "epoll/$v/$MACHINE/$VARIANT" A -cp "out:$(core_cp "$v"):$jar" AlpineNativeLoadTest A "$jar" "epoll/$v/$MACHINE/$VARIANT"
done

for v in $TCNATIVE_VERSIONS; do
  jar="libs/netty-tcnative-boringssl-static-$v-$CLS.jar"
  [ -f "$jar" ] || continue
  rm -rf /tmp/x && mkdir -p /tmp/x && unzip -qo "$jar" -d /tmp/x
  so=$(find /tmp/x -name '*.so' | head -1)
  ./elf-scan.sh "$so" "tcnative-$v-$SOARCH"
  run_check "tcnative/$v/$MACHINE/$VARIANT" A -cp "out:libs/netty-tcnative-classes-$v.jar" \
       AlpineNativeLoadTest A "$jar" "tcnative/$v/$MACHINE/$VARIANT"
done

# ---------------------------------------------------------------- positive control
ap="libs/libasyncProfiler-$SOARCH.so"
if [ -f "$ap" ]; then
  ./elf-scan.sh "$ap" "asyncProfiler-$SOARCH"
  run_check "asyncProfiler/4.1/$MACHINE/$VARIANT" A -cp out AlpineNativeLoadTest A "$ap" "asyncProfiler/4.1/$MACHINE/$VARIANT"
fi

# ---------------------------------------------------------------- Level B: real API
for v in $EPOLL_VERSIONS; do
  jar="libs/netty-transport-native-epoll-$v-$CLS.jar"
  [ -f "$jar" ] || continue
  run_check "epoll/$v/$MACHINE/$VARIANT" B-epoll -cp "out:$(core_cp "$v"):$jar" AlpineNativeLoadTest B epoll "epoll/$v/$MACHINE/$VARIANT"
done

for v in $TCNATIVE_VERSIONS; do
  jar="libs/netty-tcnative-boringssl-static-$v-$CLS.jar"
  [ -f "$jar" ] || continue
  run_check "tcnative/$v/$MACHINE/$VARIANT" B-openssl -cp "out:$(core_cp "$OPENSSL_NETTY_VERSION"):libs/netty-tcnative-classes-$v.jar:$jar" \
       AlpineNativeLoadTest B openssl "tcnative/$v/$MACHINE/$VARIANT"
done

# ------------------------------------------------- Level D: real TLS handshake
# Loading the library proves nothing about the crypto. This drives a full TLS handshake
# plus application data through BoringSSL. Compiled separately because it imports netty
# directly, unlike the reflection-only AlpineNativeLoadTest.
for v in $TCNATIVE_VERSIONS; do
  jar="libs/netty-tcnative-boringssl-static-$v-$CLS.jar"
  [ -f "$jar" ] || continue
  cp="$(core_cp "$OPENSSL_NETTY_VERSION"):libs/netty-tcnative-classes-$v.jar:$jar"
  mkdir -p out-tls
  if javac -nowarn -d out-tls -cp "$cp" src/TlsHandshakeTest.java 2>/dev/null; then
    run_check "tcnative/$v/$MACHINE/$VARIANT" D-handshake -cp "out-tls:$cp" \
      TlsHandshakeTest "tcnative/$v/$MACHINE/$VARIANT"
  else
    echo "RESULT	tcnative/$v/$MACHINE/$VARIANT	D-handshake	FAIL	javac failed"
  fi
done

# ---------------------------------------------------------------- feasibility probe
# Only meaningful on the bare variant: does the async-profiler recipe (drop the ld-linux
# DT_NEEDED + supply the missing glibc symbols) make the RELEASED artifacts loadable?
if [ "$VARIANT" = "bare" ]; then
  echo "######## FEASIBILITY PROBE (async-profiler recipe, bare Alpine)"
  gcc -shared -fPIC -o /tmp/musl_shim.so shim/musl_shim.c || echo "shim build failed" >&2

  probe() { # jar label
    local jar="$1" label="$2"
    rm -rf /tmp/p && mkdir -p /tmp/p && unzip -qo "$jar" -d /tmp/p
    local so; so=$(find /tmp/p -name '*.so' | head -1)

    local cp="$3"
    # step 1: drop the ld-linux DT_NEEDED, exactly as async-profiler's Makefile:156 does
    patchelf --remove-needed ld-linux-x86-64.so.2 --remove-needed ld-linux-aarch64.so.1 "$so" 2>/dev/null
    run_check "$label+patchelf" A -cp "$cp" AlpineNativeLoadTest A "$so" "$label+patchelf"

    # step 2: additionally preload the weak-symbol shim
    PRELOAD=/tmp/musl_shim.so \
      run_check "$label+patchelf+shim" A -cp "$cp" AlpineNativeLoadTest A "$so" "$label+patchelf+shim"
    PRELOAD=
  }

  # epoll is deliberately not probed: its ELF scan reports no unresolvable symbols and no
  # unreserved DT_NEEDED, so there is nothing for the recipe to fix.
  for v in $TCNATIVE_VERSIONS; do
    [ -f "libs/netty-tcnative-boringssl-static-$v-$CLS.jar" ] &&
      probe "libs/netty-tcnative-boringssl-static-$v-$CLS.jar" "tcnative/$v/$MACHINE" \
            "out:libs/netty-tcnative-classes-$v.jar"
  done
fi

echo "######## DONE $MACHINE/$VARIANT"
