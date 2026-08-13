#!/usr/bin/env bash
# Verifies a netty-tcnative boringssl-static build tree. Run INSIDE a container that has
# binutils (e.g. tcnative-build), with the module's target/ dir as $1.
#
#   verify-built-lib.sh <boringssl-static/target>
#
# Checks, in order of what actually goes wrong:
#   1. BoringSSL was really built for THIS arch (catches the stale-directory trap that
#      silently falls back to the host's shared system OpenSSL - see REPORT.md 6c)
#   2. DT_NEEDED before vs after the strip+patchelf step
#   3. the weak musl fallbacks are present and the glibc-internal imports are gone
set -uo pipefail
T="${1:?usage: verify-built-lib.sh <boringssl-static/target>}"
cd "$T"

needed() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '; }

echo "== 1. BoringSSL static archives"
for f in boringssl-main/build/libssl.a boringssl-main/build/libcrypto.a; do
  if [ -f "$f" ]; then
    echo "   $(basename "$f"): $(objdump -f "$f" 2>/dev/null | grep -m1 'architecture' | sed 's/^[[:space:]]*//')"
  else
    echo "   $(basename "$f"): MISSING -- build may have fallen back to system OpenSSL"
  fi
done

PRE=$(find native-build/target/lib -name 'libnetty_tcnative*.so*' -type f 2>/dev/null | head -1)
POST=native-lib-only/META-INF/native/linux64/libnetty_tcnative.so

echo "== 2. DT_NEEDED"
echo "   before patchelf: $(needed "$PRE")"
echo "   after  patchelf: $(needed "$POST")"
for bad in libssl.so libcrypto.so; do
  if needed "$POST" | grep -q "$bad"; then
    echo "   !! FAIL: $bad in DT_NEEDED -- this is NOT a static BoringSSL build"
  fi
done
if needed "$POST" | grep -qE 'ld-linux'; then
  echo "   !! FAIL: ld-linux still present -- patchelf step did not take effect"
else
  echo "   ok: no ld-linux entry"
fi

echo "== 3. musl fallback symbols"
readelf --dyn-syms -W "$POST" 2>/dev/null \
  | awk '$8 ~ /^(__getauxval|fopen64|__isinf|__isnan|__strdup)$/ {printf "   %-6s %-8s %s\n", $5, $7, $8}'
STILL=$(readelf --dyn-syms -W "$POST" 2>/dev/null | awk '$7=="UND"{print $8}' \
        | grep -E '^(__getauxval|__isinf|__isnan|__strdup|fopen64)$' | sort -u | tr '\n' ' ')
if [ -n "$STILL" ]; then echo "   !! FAIL: still undefined: $STILL"; else echo "   ok: none still undefined"; fi

echo "== 4. stripped?"
if [ "$(readelf -S -W "$POST" 2>/dev/null | grep -c '\.debug_')" = "0" ]; then
  echo "   ok: no .debug_* sections (strip ran)"
else
  echo "   note: debug sections present (strip did not run)"
fi
