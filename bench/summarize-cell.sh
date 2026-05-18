#!/usr/bin/env bash
#
# summarize-cell.sh — measure one ablation cell N times, reduce to a per-cell
# median result.
#
#   ./bench/summarize-cell.sh <CELL_ID> [RUNS] [MODE]
#
# Calls bench/measure-cell.sh RUNS times (default 3), parses every build log
# with bench/parse-build-log.sh, and writes a per-cell median + spread file
# that bench/contribution-table.sh consumes:
#
#   MODE full  (default) -> bench/results/<CELL>.txt        (cold + warm)
#   MODE fresh           -> bench/results/<CELL>-fresh.txt  (fresh-runner build)
#
# The measurement matrix in .github/workflows/build-benchmark.yml runs this
# once per cell. See docs/measurement-methodology.md ("측정 신뢰성 절차").
#
set -euo pipefail

CELL="${1:?usage: summarize-cell.sh <CELL_ID> [RUNS] [MODE]}"
RUNS="${2:-3}"
MODE="${3:-full}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PARSE="bench/parse-build-log.sh"
mkdir -p bench/results

row="$(awk -F'\t' -v c="$CELL" '$1 == c' bench/cells.tsv)"
[ -n "$row" ] || { echo "unknown cell: $CELL" >&2; exit 1; }
IFS=$'\t' read -r _ proto _ _ _ _ _ _ _ _ _ note <<<"$row"

# --- run the measurements -------------------------------------------------
for r in $(seq 1 "$RUNS"); do
  ./bench/measure-cell.sh "$CELL" "$r" "$MODE"
done

# med <phase> <metric> -> "median min max" across the RUNS logs ("NA NA NA"
# when no run produced the metric). phase is cold|warm|fresh.
med() {
  local phase="$1" key="$2" r v nums=""
  for r in $(seq 1 "$RUNS"); do
    v="$(bash "$PARSE" "bench/results/${CELL}-run${r}-${phase}.log" \
          | awk -F= -v k="$key" '$1 == k { print $2 }')"
    [ -n "$v" ] && [ "$v" != "NA" ] && nums="$nums $v"
  done
  [ -n "${nums// /}" ] || { echo "NA NA NA"; return; }
  # shellcheck disable=SC2086
  bash "$PARSE" --stats $nums | awk '{
    for (i = 1; i <= NF; i++) { split($i, kv, "="); m[kv[1]] = kv[2] }
    print m["median"], m["min"], m["max"]
  }'
}

if [ "$MODE" = "full" ]; then
  out="bench/results/${CELL}.txt"
  read -r cb cb_lo cb_hi <<<"$(med cold layer_b)"
  read -r wb wb_lo wb_hi <<<"$(med warm layer_b)"
  read -r ca _ _         <<<"$(med cold layer_a)"
  read -r cc _ _         <<<"$(med cold layer_c)"
  read -r cbc _ _        <<<"$(med cold layer_b_compile)"
  read -r cbl _ _        <<<"$(med cold layer_b_link)"
  read -r wch _ _        <<<"$(med warm ccache_hit)"
  read -r img _ _        <<<"$(med warm image_gb)"
  {
    echo "cell=$CELL"
    echo "protocol=$proto"
    echo "note=$note"
    echo "cold_layer_b=$cb"
    echo "cold_layer_b_lo=$cb_lo"
    echo "cold_layer_b_hi=$cb_hi"
    echo "warm_layer_b=$wb"
    echo "warm_layer_b_lo=$wb_lo"
    echo "warm_layer_b_hi=$wb_hi"
    echo "cold_layer_a=$ca"
    echo "cold_layer_c=$cc"
    echo "cold_layer_b_compile=$cbc"
    echo "cold_layer_b_link=$cbl"
    echo "warm_ccache=$wch"
    echo "image_gb=$img"
  } > "$out"
else
  out="bench/results/${CELL}-fresh.txt"
  read -r fb fb_lo fb_hi <<<"$(med fresh layer_b)"
  read -r fch _ _        <<<"$(med fresh ccache_hit)"
  read -r fsh _ _        <<<"$(med fresh sccache_hits)"
  read -r fsr _ _        <<<"$(med fresh sccache_requests)"
  read -r img _ _        <<<"$(med fresh image_gb)"
  {
    echo "cell=$CELL"
    echo "protocol=$proto"
    echo "note=$note"
    echo "fresh_layer_b=$fb"
    echo "fresh_layer_b_lo=$fb_lo"
    echo "fresh_layer_b_hi=$fb_hi"
    echo "fresh_ccache=$fch"
    echo "fresh_sccache_hits=$fsh"
    echo "fresh_sccache_requests=$fsr"
    echo "image_gb=$img"
  } > "$out"
fi

echo "wrote $out"
cat "$out"

# Fail loud on an empty measurement. The build always emits a LAYER_B marker,
# so an NA layer_b means the parse step failed — not a legitimate empty result.
# Without this guard a parse failure passes as a green job with NA-filled data.
if [ "$MODE" = "full" ]; then
  [ "$cb" != "NA" ] || { echo "FATAL: $CELL cold_layer_b is NA — parse/measurement failed" >&2; exit 1; }
else
  [ "$fb" != "NA" ] || { echo "FATAL: $CELL fresh_layer_b is NA — parse/measurement failed" >&2; exit 1; }
fi
