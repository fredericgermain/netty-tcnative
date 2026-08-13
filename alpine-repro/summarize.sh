#!/usr/bin/env bash
# Renders the results/*.log files into the markdown tables used by REPORT.md.
set -uo pipefail
cd "$(dirname "$0")"

# ---- load-result matrix: rows = artifact/version, cols = arch/variant
echo "### Load results"
echo
{
  printf 'artifact\tversion\t'
  printf 'x86_64 bare\tx86_64 gcompat\taarch64 bare\taarch64 gcompat\tglibc\n'
  for spec in "epoll 4.2.12.Final" "epoll 4.2.17.Final" \
              "tcnative 2.0.65.Final" "tcnative 2.0.73.Final" \
              "tcnative 2.0.75.Final" "tcnative 2.0.81.Final" \
              "asyncProfiler 4.1"; do
    set -- $spec; art=$1; ver=$2
    printf '%s\t%s' "$art" "$ver"
    for cell in "x86_64/bare" "x86_64/gcompat" "aarch64/bare" "aarch64/gcompat" "aarch64/glibc"; do
      # prefer the real-API verdict (Level B); fall back to the raw load (Level A)
      st=$(grep -h "^RESULT	$art/$ver/$cell	B-" results/*.log 2>/dev/null | head -1 | cut -f4)
      [ -z "$st" ] && st=$(grep -h "^RESULT	$art/$ver/$cell	A	" results/*.log 2>/dev/null | head -1 | cut -f4)
      printf '\t%s' "${st:-n/a}"
    done
    printf '\n'
  done
} | column -t -s $'\t'

echo
echo "### Unresolvable symbols on bare Alpine"
echo
for a in amd64 arm64; do
  [ -f "results/$a-bare.log" ] || continue
  awk -v a="$a" '/^######## ELF-SCAN/{lbl=$3; buf=""}
       /UNRESOLVABLE: none/{printf "  %-6s %-34s none\n", a, lbl}
       /UNRESOLVABLE:$/{f=1; next}
       f&&/^     /{gsub(/^ +/,""); buf=buf $0 " "; next}
       f{printf "  %-6s %-34s %s\n", a, lbl, buf; f=0}' "results/$a-bare.log"
done

echo
echo "### Feasibility probe (async-profiler recipe, bare Alpine)"
echo
grep -h '^RESULT' results/*.log 2>/dev/null | grep 'patchelf' \
  | awk -F'\t' '{printf "  %-46s %-5s %.60s\n", $2, $4, $5}' | sort
