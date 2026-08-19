#!/bin/bash
#
# Emit the GHCR refs for one build-environment image, as GITHUB_OUTPUT-ready lines:
#
#   ref=ghcr.io/<owner>/<repo>/buildenv:<setup>-<hash>    the content-addressed image
#   latest=ghcr.io/<owner>/<repo>/buildenv:<setup>-latest the moving alias, used only to
#                                                         warm a fallback build
#
# Usage: buildenv_tag.sh <repository> <setup> <input-file>...
#
# The hash covers the input files plus OPENSSL_VERSION/OPENSSL_SHA256 from the environment,
# which the workflows extract from pom.xml. That is a complete description of the image
# because none of the Dockerfiles under docker/ contains a COPY or an ADD: the `context: ../`
# every compose file declares is never read, so no repository content reaches the image and
# an image is a pure function of its Dockerfile text plus the build args the compose files
# supply. check_no_context_reads() below enforces that - the day someone adds a COPY, the
# hash stops describing the image and CI would otherwise silently run in a stale environment.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <repository> <setup> <input-file>..." >&2
  exit 2
fi

repository="$1"; shift
setup="$1"; shift

# Registry paths are lowercase-only; a fork owner may be spelled with capitals.
repository="$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')"

# Fail loudly if the "no repository content in the image" invariant has been broken, rather
# than serving an image whose tag no longer describes its contents.
check_no_context_reads() {
  local offenders
  offenders="$(grep -lniE '^[[:space:]]*(copy|add)[[:space:]]' "$@" || true)"
  if [ -n "$offenders" ]; then
    echo "buildenv_tag.sh: COPY/ADD found in: $offenders" >&2
    echo "  These images are tagged by a hash of their Dockerfile and build args only." >&2
    echo "  Reading the build context makes that hash wrong, and CI would silently reuse" >&2
    echo "  a stale image. Either drop the COPY/ADD, or add its sources to image-inputs." >&2
    exit 1
  fi
}
check_no_context_reads "$@"

if command -v sha256sum >/dev/null 2>&1; then
  hash_cmd=(sha256sum)
else
  hash_cmd=(shasum -a 256)
fi

hash="$(
  {
    printf '%s\n' "${OPENSSL_VERSION:-}" "${OPENSSL_SHA256:-}"
    cat "$@"
  } | "${hash_cmd[@]}" | cut -c1-16
)"

echo "ref=ghcr.io/${repository}/buildenv:${setup}-${hash}"
echo "latest=ghcr.io/${repository}/buildenv:${setup}-latest"
