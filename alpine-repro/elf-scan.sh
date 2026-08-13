#!/usr/bin/env bash
# Static + dynamic diagnosis of a native .so, run INSIDE the Alpine container so that
# "what is available" reflects the actual package set installed in this variant.
#
# usage: elf-scan.sh <path-to-.so> [label]
set -uo pipefail

SO="$1"
LABEL="${2:-$(basename "$SO")}"
ARCH="$(uname -m)"

echo "######## ELF-SCAN $LABEL  ($ARCH)"

# ---------------------------------------------------------------- DT_NEEDED
# musl's loader satisfies a fixed set of libc alias names from musl itself, without ever
# touching the filesystem -- ldso/dynlink.c:1074-1084:
#     static const char reserved[] = "c.pthread.rt.m.dl.util.xnet.";
# Anything else is a real file lookup and can fail on a bare Alpine system.
musl_reserved() {
  case "$1" in
    libc.*|libpthread.*|librt.*|libm.*|libdl.*|libutil.*|libxnet.*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "-- DT_NEEDED"
readelf -d "$SO" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | while read -r lib; do
  if musl_reserved "$lib"; then
    echo "   OK        $lib   (musl-reserved, resolved internally)"
  elif [ -e "/lib/$lib" ] || [ -e "/usr/lib/$lib" ]; then
    tgt=$(readlink -f "/lib/$lib" 2>/dev/null || readlink -f "/usr/lib/$lib")
    echo "   OK        $lib   -> $tgt"
  else
    echo "   MISSING   $lib   (not reserved, not present)"
  fi
done

# ---------------------------------------------------------------- ldd (ground truth)
# On Alpine `ldd` IS the musl loader; it prints the real relocation errors with no JVM
# in the way. This is the authoritative dynamic-linking verdict.
echo "-- ldd (musl loader)"
ldd "$SO" 2>&1 | sed 's/^/   /' | head -40

# ---------------------------------------------------------------- undefined symbols
# Collect symbols actually provided by whatever is installed in this variant.
PROVIDERS=""
GNU_TRIPLE="$ARCH-linux-gnu"
for p in "/lib/ld-musl-$ARCH.so.1" /usr/lib/libgcompat.so.0 /usr/lib/libstdc++.so.6 \
         /usr/lib/libgcc_s.so.1 "/lib/libc.musl-$ARCH.so.1" \
         "/lib/$GNU_TRIPLE/libc.so.6" "/lib/$GNU_TRIPLE/libm.so.6" \
         "/lib/$GNU_TRIPLE/libpthread.so.0" "/lib/$GNU_TRIPLE/libdl.so.2" \
         "/lib/$GNU_TRIPLE/librt.so.1" "/lib/$GNU_TRIPLE/libgcc_s.so.1" \
         "/usr/lib/$GNU_TRIPLE/libstdc++.so.6"; do
  [ -e "$p" ] && PROVIDERS="$PROVIDERS $p"
done
echo "-- symbol providers present:$PROVIDERS"

AVAIL=$(mktemp)
for p in $PROVIDERS; do
  nm -D --defined-only "$p" 2>/dev/null | awk '{print $NF}'
done | sed 's/@.*//' | sort -u > "$AVAIL"

# -W is essential: without it readelf truncates long symbol names and appends "[...]".
# Only GLOBAL undefined symbols matter. WEAK undefined symbols (e.g. __gmon_start__,
# _ITM_*, epoll_pwait2) are allowed to stay unresolved -- they resolve to 0 at runtime.
UND=$(mktemp)
readelf -W --dyn-syms "$SO" 2>/dev/null \
  | awk '$7=="UND" && $5=="GLOBAL" {print $8}' \
  | sed 's/@.*//' | grep -v '^$' | sort -u > "$UND"

echo "-- undefined GLOBAL symbols: $(wc -l < "$UND" | tr -d ' ')"
MISSING=$(comm -23 "$UND" "$AVAIL")
if [ -z "$MISSING" ]; then
  echo "   UNRESOLVABLE: none"
else
  echo "   UNRESOLVABLE:"
  echo "$MISSING" | sed 's/^/     /'
fi

rm -f "$AVAIL" "$UND"
echo
