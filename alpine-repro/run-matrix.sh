#!/usr/bin/env bash
# Drives the full matrix: {arm64, amd64} x {bare, libc6-compat, gcompat, full}.
#
#   ./run-matrix.sh                 # both arches
#   ./run-matrix.sh --arch arm64    # native on Apple Silicon, fast
#   ./run-matrix.sh --arch amd64    # qemu-emulated, slow
#   ./run-matrix.sh --glibc         # glibc control run (Ubuntu base)
set -uo pipefail
cd "$(dirname "$0")"

ARCHES="arm64 amd64"
GLIBC_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCHES="$2"; shift 2 ;;
    --glibc) GLIBC_ONLY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p results

# This machine runs Docker inside Colima with k3s enabled. k3s/kube-router installs
# `-P FORWARD DROP` ahead of DOCKER-FORWARD, so containers on the default bridge get no
# outbound TCP (the VM itself is fine). --network=host sidesteps the bridge entirely and
# leaves the k3s firewall rules untouched. Harmless on a normal Docker host.
NET="${NET:---network=host}"

# variant -> apk packages installed into that image
variant_pkgs() {
  case "$1" in
    bare)         echo "" ;;
    # On Alpine 3.23 libc6-compat is a `provides` of gcompat, so this variant installs
    # gcompat and is expected to match the gcompat column.
    # NB: an "X (no such package)" error here is usually NOT a naming problem -- under
    # qemu emulation the APKINDEX fetch times out first, and apk then reports every
    # requested package as missing. Check the WARNING lines above it.
    libc6-compat) echo "libc6-compat" ;;
    gcompat)      echo "gcompat" ;;
    full)         echo "gcompat libstdc++ libgcc" ;;
  esac
}
VARIANTS="bare libc6-compat gcompat full"

# ---------------------------------------------------------------- glibc control
if [ "$GLIBC_ONLY" = 1 ]; then
  echo "== glibc control (eclipse-temurin:21-jdk-jammy, arm64)"
  docker build $NET --platform=linux/arm64 -q -t netty-alpine-repro:glibc -f Dockerfile.glibc . >/dev/null || exit 1
  docker run --rm $NET --platform=linux/arm64 -v "$PWD":/w -w /w \
    -e EPOLL_VERSIONS -e TCNATIVE_VERSIONS netty-alpine-repro:glibc \
    bash /w/in-container.sh glibc 2>&1 | tee results/glibc-arm64.log
  exit 0
fi

# ---------------------------------------------------------------- alpine matrix
for arch in $ARCHES; do
  if ! docker run --rm $NET --platform="linux/$arch" alpine:3.17 uname -m >/dev/null 2>&1; then
    echo "!! cannot run linux/$arch containers (binfmt/qemu missing) -- SKIPPING $arch" >&2
    continue
  fi

  for variant in $VARIANTS; do
    # Tag must include the arch: building the same tag for a second platform silently
    # replaces the first one's image.
    tag="netty-alpine-repro:$arch-$variant"
    echo "== building $tag ($arch)"
    # apk/apt occasionally flakes through --network=host while an emulated build is
    # running concurrently; one retry keeps a whole variant from being lost.
    docker build $NET --platform="linux/$arch" -t "$tag" \
      --build-arg EXTRA_PKGS="$(variant_pkgs "$variant")" \
      -f Dockerfile.alpine . >/dev/null 2>&1 ||
    docker build $NET --platform="linux/$arch" -t "$tag" \
      --build-arg EXTRA_PKGS="$(variant_pkgs "$variant")" \
      -f Dockerfile.alpine . >/dev/null || { echo "build failed for $tag" >&2; continue; }

    log="results/$arch-$variant.log"
    echo "== running $arch/$variant -> $log"
    docker run --rm $NET --platform="linux/$arch" -v "$PWD":/w -w /w \
      -e EPOLL_VERSIONS -e TCNATIVE_VERSIONS "$tag" \
      bash /w/in-container.sh "$variant" > "$log" 2>&1
    grep -c '^RESULT' "$log" | xargs -I{} echo "   {} result lines"
  done
done

# ---------------------------------------------------------------- summary
{
  printf 'target\tlevel\tstatus\tdetail\n'
  grep -h '^RESULT' results/*.log 2>/dev/null | cut -f2-
} > results/summary.tsv

echo
echo "Summary written to results/summary.tsv ($(( $(wc -l < results/summary.tsv) - 1 )) rows)"
