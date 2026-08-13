#!/usr/bin/env bash
# Makes a RELEASED netty-tcnative classifier jar loadable on Alpine/musl by ELF surgery
# only -- no source rebuild. Use this to unblock now; the real fix belongs in the build.
#
#   ./patch-released-jar.sh <input.jar> [output.jar]
#
# What it does, per architecture (see REPORT.md for why):
#   x86_64  : patchelf --remove-needed ld-linux-x86-64.so.2
#             `ld-linux-*` is not a musl-reserved name so the lookup fails, but musl itself
#             defines the symbol behind it (__tls_get_addr). Dropping the entry is enough.
#             => works on BARE Alpine, no extra packages.
#   aarch64 : patchelf --add-needed libgcompat.so.0
#             Deliberately restores what 2.0.65 got by accident via libcrypt.so.1: a
#             NON-reserved name that actually pulls libgcompat.so.0 into the process, which
#             defines __getauxval. musl short-circuits gcompat's own libc.so.6 symlink, so
#             an explicit non-reserved DT_NEEDED is the only way to get gcompat loaded.
#             => REQUIRES `apk add gcompat` in the runtime image.
#             Alternative with no runtime package: LD_PRELOAD shim/musl_shim.c
#
# patchelf does not exist on macOS hosts, so the work happens inside the Alpine image
# (patchelf is arch-agnostic -- the arm64 image can edit x86_64 ELFs and vice versa).
set -euo pipefail
cd "$(dirname "$0")"

IN="${1:?usage: patch-released-jar.sh <input.jar> [output.jar]}"
[ -f "$IN" ] || { echo "no such jar: $IN" >&2; exit 1; }
OUT="${2:-${IN%.jar}-musl.jar}"

IMAGE="${IMAGE:-netty-alpine-repro:arm64-bare}"
NET="${NET:---network=host}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "building $IMAGE ..." >&2
  docker build $NET --platform=linux/arm64 -t "$IMAGE" --build-arg EXTRA_PKGS="" -f Dockerfile.alpine . >/dev/null
}

WORK=$(mktemp -d ./.patchwork.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cp "$IN" "$WORK/in.jar"

docker run --rm $NET --platform=linux/arm64 -v "$PWD/$WORK":/work -w /work "$IMAGE" bash -c '
set -euo pipefail
mkdir -p x && unzip -qo in.jar -d x
so=$(find x/META-INF/native -name "*.so" | head -1)
[ -n "$so" ] || { echo "no META-INF/native/*.so inside jar" >&2; exit 1; }
echo "  lib:    $(basename "$so")"
echo "  before: $(readelf -d "$so" | sed -n "s/.*(NEEDED).*\[\(.*\)\]/\1/p" | tr "\n" " ")"

case "$(basename "$so")" in
  *x86_64*)  patchelf --remove-needed ld-linux-x86-64.so.2 "$so"
             patchelf --remove-needed ld-linux-aarch64.so.1 "$so" 2>/dev/null || true
             echo "  action: removed ld-linux DT_NEEDED (bare Alpine OK)" ;;
  *aarch_64*) patchelf --add-needed libgcompat.so.0 "$so"
             echo "  action: added libgcompat.so.0 DT_NEEDED (requires: apk add gcompat)" ;;
  *) echo "unrecognised arch in $(basename "$so")" >&2; exit 1 ;;
esac

echo "  after:  $(readelf -d "$so" | sed -n "s/.*(NEEDED).*\[\(.*\)\]/\1/p" | tr "\n" " ")"
# Repack everything, not just META-INF/native -- the jar also carries MANIFEST.MF and the
# maven descriptors, and Netty resolves the lib as a classpath resource.
# -M so jar does not synthesise a fresh manifest over the one already in the tree.
(cd x && jar cfM ../out.jar .)
'

mv "$WORK/out.jar" "$OUT"
echo "  wrote:  $OUT"
