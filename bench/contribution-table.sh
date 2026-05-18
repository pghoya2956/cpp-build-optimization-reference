#!/usr/bin/env bash
#
# contribution-table.sh — render the ablation result tables from the per-cell
# medians written by bench/summarize-cell.sh.
#
#   ./bench/contribution-table.sh <results-dir>
#
# Emits GitHub-flavoured markdown to stdout: the core ablation table, the
# protocol A marginal / protocol B residual contribution tables, the
# multi-target table and the cache-backend table. The build-benchmark workflow
# appends this to its job summary. See docs/measurement-methodology.md.
#
set -euo pipefail

DIR="${1:?usage: contribution-table.sh <results-dir>}"

# field <cell> <key> [suffix] -> value from <DIR>/<cell><suffix>.txt, or "-"
field() {
  local f="$DIR/$1${3:-}.txt"
  [ -f "$f" ] || { echo "-"; return; }
  local v
  v="$(awk -F= -v k="$2" '$1 == k { print $2 }' "$f")"
  if [ -z "$v" ] || [ "$v" = "NA" ]; then echo "-"; else echo "$v"; fi
}

# vflag <median> <lo> <hi> -> " ⚠" when the spread exceeds 15% of the median
vflag() {
  awk -v m="$1" -v lo="$2" -v hi="$3" 'BEGIN {
    if (m == "-" || lo == "-" || hi == "-" || m + 0 == 0) { print ""; exit }
    print ((hi - lo) / m > 0.15) ? " ⚠" : ""
  }'
}

# delta <a> <b> -> signed (a - b), or "-" when either operand is missing
delta() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (a == "-" || b == "-") { print "-"; exit }
    printf "%+.1f", a - b
  }'
}

echo "### 코어 ablation — layer B 측정값 (초, N-run 중앙값)"
echo
echo "headline 이 아니라 \`cmake --build\` 구간(layer B)만 격리한 값. ⚠ = 분산이 중앙값의 15% 초과."
echo
echo "| cell | 설명 | cold L_B | warm L_B | L_A | L_C |"
echo "|---|---|--:|--:|--:|--:|"
for c in A0 A1 A2 A3 A4 A5 A6 B1 B2 B3 B4 B5 B6; do
  note="$(field "$c" note)"
  cb="$(field "$c" cold_layer_b)";  cblo="$(field "$c" cold_layer_b_lo)"; cbhi="$(field "$c" cold_layer_b_hi)"
  wb="$(field "$c" warm_layer_b)";  wblo="$(field "$c" warm_layer_b_lo)"; wbhi="$(field "$c" warm_layer_b_hi)"
  echo "| $c | $note | ${cb}$(vflag "$cb" "$cblo" "$cbhi") | ${wb}$(vflag "$wb" "$wblo" "$wbhi") | $(field "$c" cold_layer_a) | $(field "$c" cold_layer_c) |"
done
echo

echo "### 프로토콜 A — 한계 기여 (누적 add, warm layer B 기준)"
echo
echo "각 단계에서 기법을 하나 추가했을 때 줄어든 warm layer B 시간. 양수 = 단축."
echo
echo "| 추가 기법 | cell | warm L_B | 한계 기여 Δ |"
echo "|---|---|--:|--:|"
prev="$(field A0 warm_layer_b)"
for pair in "Ninja:A1" "ccache:A2" "PCH:A3" "unity:A4" "split-dwarf:A5" "mold:A6"; do
  tech="${pair%%:*}"; c="${pair##*:}"
  cur="$(field "$c" warm_layer_b)"
  echo "| +$tech | $c | $cur | $(delta "$prev" "$cur") |"
  prev="$cur"
done
echo

echo "### 프로토콜 B — 잔여 기여 (leave-one-out, optimized 대비)"
echo
echo "optimized(=A6)에서 기법을 하나 제거했을 때 늘어난 warm layer B 시간. 양수 = 그 기법이 없으면 느려짐."
echo
echo "| 제거 기법 | cell | warm L_B | 잔여 기여 Δ |"
echo "|---|---|--:|--:|"
b0="$(field A6 warm_layer_b)"
for pair in "ccache:B1" "unity:B2" "PCH:B3" "mold:B4" "split-dwarf:B5" "Ninja:B6"; do
  tech="${pair%%:*}"; c="${pair##*:}"
  cur="$(field "$c" warm_layer_b)"
  echo "| -$tech | $c | $cur | $(delta "$cur" "$b0") |"
done
echo

echo "### 다중타깃 변형 — mold 구조 의존성 (cold layer B, 초)"
echo
echo "96 TU를 단일 실행파일 / 16 STATIC lib / 16 SHARED lib으로 묶어 mold on·off 대조."
echo "mold는 ld 가속기 — static(ar)에선 작업량이 안 늘고 shared(ld 16회)에서만 곱해진다."
echo "컴파일/링크 분리 측정은 split 셀(M3~M6)에서만."
echo
echo "| cell | 설명 | L_B compile | L_B link | L_B total |"
echo "|---|---|--:|--:|--:|"
for c in M1 M2 M3 M4 M5 M6; do
  echo "| $c | $(field "$c" note) | $(field "$c" cold_layer_b_compile) | $(field "$c" cold_layer_b_link) | $(field "$c" cold_layer_b) |"
done
echo

echo "### 캐시 백엔드 변형 — ephemeral 러너 캐시 공유"
echo
echo "C1 = 같은 잡 warm(ccache 로컬 디스크). C2/C3 = 새 잡(fresh 러너) 빌드 — ccache 로컬은 증발(적중 0%), sccache+S3 는 버킷 공유로 적중."
echo
echo "| cell | 설명 | layer B | ccache hit % | sccache hits |"
echo "|---|---|--:|--:|--:|"
echo "| C1 | $(field C1 note) | $(field C1 warm_layer_b) | $(field C1 warm_ccache) | - |"
for c in C2 C3; do
  echo "| $c | $(field "$c" note -fresh) | $(field "$c" fresh_layer_b -fresh) | $(field "$c" fresh_ccache -fresh) | $(field "$c" fresh_sccache_hits -fresh) |"
done
