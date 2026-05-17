#!/usr/bin/env bash
#
# parse-build-log.sh — pull the benchmark numbers out of a build log.
#
# Works on `docker buildx build --progress=plain` output, on the logs the
# bench/ measurement scripts write, and on CI step logs. The measurement
# boundary is the `docker buildx build` wall time; the in-container
# `cmake --build` time and ccache hit rate are reported separately.
#
#   ./bench/parse-build-log.sh <logfile>
#
set -euo pipefail

LOG="${1:?usage: parse-build-log.sh <logfile>}"
[ -f "$LOG" ] || { echo "no such log: $LOG" >&2; exit 1; }

echo "== build metrics: $LOG =="

# Wall time + image size — explicit markers emitted by the bench scripts / CI.
echo "-- wall time / image size --"
grep -oE '(COLD|WARM|OPT)_BUILD_SECONDS=[0-9]+|IMAGE_SIZE=[^ ]+' "$LOG" \
  || echo "(no explicit markers)"

# In-container compile time — the CMake build line from --progress=plain.
echo "-- compile (cmake --build) --"
grep -oE 'Built target cbor' "$LOG" >/dev/null 2>&1 \
  && grep -oE '#[0-9]+ [0-9.]+ \[100%\] Built target' "$LOG" | tail -1 \
  || echo "(no 'Built target' line)"

# ccache hit rate.
echo "-- ccache --"
grep -E 'Hits:|Misses:|Hit rate:|Cacheable calls' "$LOG" | tail -6 \
  || echo "(no ccache stats)"

# Slowest buildx steps — where the wall time actually goes.
echo "-- slowest buildx steps --"
grep -oE '#[0-9]+ DONE [0-9.]+s' "$LOG" \
  | sort -t' ' -k3 -rn | head -5 \
  || echo "(no buildx step timings)"
