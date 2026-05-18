#!/usr/bin/env bash
#
# measure-cell.sh — run one ablation cell: a cold build then a warm build.
#
#   ./bench/measure-cell.sh <CELL_ID> [RUN_INDEX] [MODE]
#
# Resolves the cell's toggles from bench/cells.tsv, builds docker/Dockerfile.
# ablation with the matching --build-arg set, and writes the build logs to
# bench/results/. bench/parse-build-log.sh turns those logs into metrics. The
# measurement matrix in .github/workflows/build-benchmark.yml calls this once
# per cell per run.
#
# MODE:
#   full  (default) — a cold build then a warm build, same job. The core and
#                     multi-target measurement.
#   fresh           — one build on a clean checkout, no prune, no warm edit.
#                     Represents a brand-new runner: the local ccache is empty,
#                     so only a shared remote cache (sccache + GitHub Actions
#                     cache) can serve it. The ephemeral-runner cache-sharing
#                     data point.
#
# The sccache cell (backend=gha in cells.tsv) additionally needs the GitHub
# Actions cache token + URL in the environment: ACTIONS_RUNTIME_TOKEN and
# ACTIONS_RESULTS_URL — the ghaction-github-runtime workflow step exposes them.
# CBOR_SPLIT_LIB_COUNT overrides the static/shared library count.
#
set -euo pipefail

CELL="${1:?usage: measure-cell.sh <CELL_ID> [RUN_INDEX] [MODE]}"
RUN_INDEX="${2:-1}"
MODE="${3:-full}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p bench/results
OUT="bench/results/${CELL}-run${RUN_INDEX}"

# --- resolve the cell row from the SSOT (bench/cells.tsv) ------------------
row="$(awk -F'\t' -v c="$CELL" '$1 == c' bench/cells.tsv)"
[ -n "$row" ] || { echo "unknown cell: $CELL (see bench/cells.tsv)" >&2; exit 1; }
IFS=$'\t' read -r _ _ t_ninja t_ccache t_pch t_unity t_sdw t_mold t_split t_backend _ t_note <<<"$row"

# --- translate the cell toggles into Dockerfile build args ----------------
[ "$t_ninja" = on ] && generator="Ninja" || generator="Unix Makefiles"
if [ "$t_ccache" = on ]; then
  [ "$t_backend" = gha ] && cxx_launcher="sccache" || cxx_launcher="ccache"
else
  cxx_launcher=""
fi
# nvcc stays on ccache even in sccache cells — sccache's nvcc support is limited.
[ "$t_ccache" = on ] && cuda_launcher="ccache" || cuda_launcher=""
[ "$t_pch" = on ]   && pch_disabled="OFF" || pch_disabled="ON"
[ "$t_unity" = on ] && unity="ON" || unity="OFF"
[ "$t_sdw" = on ]   && cxx_flags="-gsplit-dwarf" || cxx_flags=""
[ "$t_mold" = on ]  && mold="1" || mold="0"
split_libs="$t_split"   # none | static | shared — straight from cells.tsv

build_args=(
  --build-arg ABL_GENERATOR="$generator"
  --build-arg ABL_CXX_LAUNCHER="$cxx_launcher"
  --build-arg ABL_CUDA_LAUNCHER="$cuda_launcher"
  --build-arg ABL_PCH_DISABLED="$pch_disabled"
  --build-arg ABL_UNITY="$unity"
  --build-arg ABL_CXX_FLAGS="$cxx_flags"
  --build-arg ABL_MOLD="$mold"
  --build-arg ABL_SPLIT_LIBS="$split_libs"
  --build-arg ABL_SPLIT_LIB_COUNT="${CBOR_SPLIT_LIB_COUNT:-16}"
)

# The sccache cell mounts the full GitHub Actions environment as one BuildKit
# secret file — never as build args, so nothing bakes into an image layer.
# sccache runs two container layers below the runner (buildx -> cuda image), so
# opendal's ghac backend needs the whole runner environment — token, both cache
# URLs, the v2 flag and the GITHUB_* scope — threaded down to it to write. The
# workflow's crazy-max/ghaction-github-runtime step exposes the ACTIONS_* values.
secret_args=()
if [ "$cxx_launcher" = sccache ]; then
  : "${ACTIONS_RUNTIME_TOKEN:?sccache(gha) cell needs ACTIONS_RUNTIME_TOKEN — add the ghaction-github-runtime workflow step}"
  gha_env="$(mktemp)"
  trap 'rm -f "$gha_env"' EXIT
  {
    printf 'ACTIONS_RUNTIME_TOKEN=%s\n'    "${ACTIONS_RUNTIME_TOKEN}"
    printf 'ACTIONS_RESULTS_URL=%s\n'      "${ACTIONS_RESULTS_URL:-}"
    printf 'ACTIONS_CACHE_URL=%s\n'        "${ACTIONS_CACHE_URL:-}"
    printf 'ACTIONS_CACHE_SERVICE_V2=%s\n' "${ACTIONS_CACHE_SERVICE_V2:-}"
    printf 'GITHUB_REPOSITORY=%s\n'        "${GITHUB_REPOSITORY:-}"
    printf 'GITHUB_REF=%s\n'               "${GITHUB_REF:-}"
    printf 'GITHUB_RUN_ID=%s\n'            "${GITHUB_RUN_ID:-}"
  } > "$gha_env"
  secret_args=( --secret "id=gha_env,src=$gha_env" )
fi

# A persistent docker-container builder, so the warm build sees the cold build's
# ccache cache mount (the default docker driver does not persist it).
docker buildx inspect cbor-bench >/dev/null 2>&1 \
  || docker buildx create --name cbor-bench --driver docker-container >/dev/null
build=(docker buildx build --builder cbor-bench --load --progress=plain
       -f docker/Dockerfile.ablation -t "cbor-ablation:${CELL}")

echo "== cell ${CELL} (${t_note}) — run ${RUN_INDEX}, mode ${MODE} =="

# run_build <logfile> <wall-marker> <extra buildx args...>
run_build() {
  local log="$1" wmark="$2"; shift 2
  local t0; t0=$(date +%s)
  "${build[@]}" "$@" "${build_args[@]}" "${secret_args[@]}" . 2>&1 | tee "$log"
  echo "${wmark}=$(( $(date +%s) - t0 ))" | tee -a "$log"
}

case "$MODE" in
  full)
    # cold — empty BuildKit build cache and cache mounts.
    docker buildx prune -af --builder cbor-bench >/dev/null 2>&1 || true
    run_build "${OUT}-cold.log" COLD_BUILD_SECONDS --no-cache
    # warm — one source line changed (the realistic incremental case).
    echo "// ablation warm rebuild ${CELL} run ${RUN_INDEX} $(date +%s)" >> src/main.cpp
    run_build "${OUT}-warm.log" WARM_BUILD_SECONDS
    git checkout -- src/main.cpp 2>/dev/null || true
    size_log="${OUT}-warm.log"
    ;;
  fresh)
    # fresh-runner build — the local ccache starts empty, so only a shared
    # remote cache (sccache's GitHub Actions cache) can serve this. BuildKit
    # layers are cold too.
    run_build "${OUT}-fresh.log" FRESH_BUILD_SECONDS --no-cache
    size_log="${OUT}-fresh.log"
    ;;
  *)
    echo "unknown mode: $MODE (full|fresh)" >&2; exit 1 ;;
esac

size=$(docker image inspect "cbor-ablation:${CELL}" --format '{{.Size}}' \
        | awk '{printf "%.2f", $1/1e9}')
echo "IMAGE_SIZE=${size}" | tee -a "$size_log"
echo "done: cell ${CELL} run ${RUN_INDEX} mode ${MODE}"
