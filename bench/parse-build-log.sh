#!/usr/bin/env bash
#
# parse-build-log.sh — turn an ablation build log into metrics.
#
#   ./bench/parse-build-log.sh <logfile>        parse one cold/warm build log
#   ./bench/parse-build-log.sh --stats <n>...   median + min/max of N numbers
#
# Mode 1 reads a `docker buildx build --progress=plain` log produced by
# bench/measure-cell.sh and prints `key=value` lines: the layer A/B/C times,
# the wall time, the compiler-cache hit rate, sccache counters and image size.
# Mode 2 reduces N runs of one cell to a median and spread. The measurement
# matrix in .github/workflows/build-benchmark.yml consumes both. See
# docs/measurement-methodology.md ("측정 구간 격리", "측정 신뢰성 절차").
#
set -euo pipefail

# --- mode 2: median + min/max of N numbers --------------------------------
if [ "${1:-}" = "--stats" ]; then
    shift
    [ "$#" -gt 0 ] || { echo "median=NA min=NA max=NA n=0"; exit 0; }
    printf '%s\n' "$@" | sort -n | awk '
        { v[NR] = $1 }
        END {
            n = NR
            mid = int((n + 1) / 2)
            median = (n % 2) ? v[mid] : (v[mid] + v[mid + 1]) / 2.0
            printf "median=%.3f min=%.3f max=%.3f n=%d\n", median, v[1], v[n], n
        }'
    exit 0
fi

# --- mode 1: parse one build log ------------------------------------------
LOG="${1:?usage: parse-build-log.sh <logfile> | --stats <n>...}"
[ -f "$LOG" ] || { echo "no such log: $LOG" >&2; exit 1; }

# Last numeric value of a marker line (markers are emitted once, but a warm
# build that reuses a cached layer can echo a cached marker — take the last).
# `|| true`: a missing optional marker is legitimate, not a parse error.
marker() { grep -oE "$1" "$LOG" 2>/dev/null | tail -1 | grep -oE '[0-9.]+' | tail -1 || true; }

wall="$(marker '(COLD|WARM)_BUILD_SECONDS=[0-9]+')"
image_gb="$(marker 'IMAGE_SIZE=[0-9.]+')"

# layer B — explicit in-container markers. The ablation dependent variable;
# layer_b_compile / layer_b_link are emitted only by multi-target cells.
layer_b="$(marker 'LAYER_B_SECONDS=[0-9.]+')"
layer_b_compile="$(marker 'LAYER_B_COMPILE_SECONDS=[0-9.]+')"
layer_b_link="$(marker 'LAYER_B_LINK_SECONDS=[0-9.]+')"

# layer A — the toolchain-install RUN step, found by its command text and
# matched to its `#N DONE <t>s` timestamp from --progress=plain.
layer_a="$(awk '
    /^#[0-9]+ .*apt-get/                        { step = $1 }
    step != "" && $1 == step && $2 == "DONE"    { t = $3; sub(/s$/, "", t); print t; step = "" }
' "$LOG" | tail -1)"

# layer C — the final-image layer export. The `exporting layers <t>s done`
# line is the layer-export cost itself; it excludes the buildx `--load` tarball
# transfer that the docker-container driver adds to the step's own DONE time.
layer_c="$(grep -oE 'exporting layers [0-9.]+s done' "$LOG" 2>/dev/null | tail -1 | grep -oE '[0-9.]+' | tail -1 || true)"

# ccache — `Hits: N / M (P %)` from `ccache --show-stats`. No `^` anchor: in a
# build log the stats lines carry a `#N <elapsed> ` buildx prefix.
ccache_hit="$(grep -E 'Hits:' "$LOG" 2>/dev/null | tail -1 \
              | grep -oE '\([0-9.]+ ?%\)' | grep -oE '[0-9.]+' | tail -1 || true)"

# sccache — `Compile requests` / `Cache hits` / `Cache misses` from --show-stats.
# Cache hits surfacing S3 backend round-trips are the dependent variable for the
# ephemeral-runner cache-sharing comparison. The `[[:space:]]+[0-9]` tail keeps
# `Compile requests executed` / `Cache hits (C/C++)` sub-rows from matching.
sccache_requests="$(grep -E 'Compile requests[[:space:]]+[0-9]' "$LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | tail -1 || true)"
sccache_hits="$(grep -E 'Cache hits[[:space:]]+[0-9]' "$LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | tail -1 || true)"
sccache_misses="$(grep -E 'Cache misses[[:space:]]+[0-9]' "$LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | tail -1 || true)"

emit() { printf '%s=%s\n' "$1" "${2:-NA}"; }
emit wall             "$wall"
emit layer_a          "$layer_a"
emit layer_b          "$layer_b"
emit layer_b_compile  "$layer_b_compile"
emit layer_b_link     "$layer_b_link"
emit layer_c          "$layer_c"
emit image_gb         "$image_gb"
emit ccache_hit       "$ccache_hit"
emit sccache_requests "$sccache_requests"
emit sccache_hits     "$sccache_hits"
emit sccache_misses   "$sccache_misses"
