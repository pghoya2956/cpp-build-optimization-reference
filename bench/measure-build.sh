#!/usr/bin/env bash
#
# measure-build.sh — configure and build cbor inside the builder container,
# emitting the layer-B timing markers the bench parser reads.
#
# Run by docker/Dockerfile.ablation. The ablation cell's toggles arrive as ABL_*
# environment variables (the Dockerfile turns its build ARGs into them). The
# `cmake --build` call is wrapped in `date` markers *here*, inside the RUN, so
# the timestamp text never enters the BuildKit cache key — see
# docs/measurement-methodology.md ("측정 구간 격리").
#
set -euo pipefail

BUILD_DIR=build/ablation

# sccache GitHub Actions cache backend — the gha cell mounts the full GitHub
# Actions environment as one secret file (token, both cache URLs, the v2 flag,
# the GITHUB_* scope). sccache runs two container layers below the runner, so
# opendal's ghac backend needs that whole environment threaded down to it to
# write. Without the secret, sccache uses its local disk cache, so non-sccache
# cells and the local sanity build are unaffected. sccache >= 0.11 forces the
# v2 cache service (see docker/Dockerfile.ablation SCCACHE_VERSION).
if [ -s /run/secrets/gha_env ]; then
  set -a
  . /run/secrets/gha_env
  set +a
  export SCCACHE_GHA_ENABLED="on"
fi

# --- configure -------------------------------------------------------------
# Not part of layer B: the methodology times the `cmake --build` call only.
cmake -S . -B "$BUILD_DIR" -G "${ABL_GENERATOR:-Unix Makefiles}" \
  -D CMAKE_BUILD_TYPE=Debug \
  -D CMAKE_CXX_COMPILER_LAUNCHER="${ABL_CXX_LAUNCHER:-}" \
  -D CMAKE_CUDA_COMPILER_LAUNCHER="${ABL_CUDA_LAUNCHER:-}" \
  -D CMAKE_DISABLE_PRECOMPILE_HEADERS="${ABL_PCH_DISABLED:-ON}" \
  -D CMAKE_UNITY_BUILD="${ABL_UNITY:-OFF}" \
  -D CMAKE_UNITY_BUILD_BATCH_SIZE=16 \
  -D CMAKE_CXX_FLAGS="${ABL_CXX_FLAGS:-}" \
  -D CBOR_SPLIT_LIBS="${ABL_SPLIT_LIBS:-none}" \
  -D CBOR_SPLIT_LIB_COUNT="${ABL_SPLIT_LIB_COUNT:-16}" \
  -D CMAKE_JOB_POOLS=link_pool=2 \
  -D CMAKE_JOB_POOL_LINK=link_pool

# --- mold wrap -------------------------------------------------------------
# `mold -run` redirects every ld invocation in the wrapped command to mold.
# Empty array when the cell has mold off.
wrap=()
[ "${ABL_MOLD:-0}" = "1" ] && wrap=(mold -run)

# Zero the compiler-cache stats so --show-stats reflects only this build.
case "${ABL_CXX_LAUNCHER:-}" in
  ccache)  ccache -z >/dev/null ;;
  sccache) sccache --zero-stats >/dev/null ;;
esac

elapsed() { awk "BEGIN { printf \"%.3f\", $2 - $1 }"; }
cores="$(nproc)"

# --- layer B — the measured build -----------------------------------------
if [ "${ABL_SPLIT_LIBS:-none}" != "none" ]; then
  # Multi-target cell (static or shared) — time the library compiles and the
  # final link apart, so the mold linker's contribution is visible.
  count="${ABL_SPLIT_LIB_COUNT:-16}"
  libs=()
  for i in $(seq 0 $((count - 1))); do
    libs+=("$(printf 'cbor_mod_%02d' "$i")")
  done
  c0=$(date +%s.%N)
  "${wrap[@]}" cmake --build "$BUILD_DIR" --parallel "$cores" --target "${libs[@]}"
  c1=$(date +%s.%N)
  "${wrap[@]}" cmake --build "$BUILD_DIR" --parallel "$cores" --target cbor
  c2=$(date +%s.%N)
  echo "LAYER_B_COMPILE_SECONDS=$(elapsed "$c0" "$c1")"
  echo "LAYER_B_LINK_SECONDS=$(elapsed "$c1" "$c2")"
  echo "LAYER_B_SECONDS=$(elapsed "$c0" "$c2")"
else
  b0=$(date +%s.%N)
  "${wrap[@]}" cmake --build "$BUILD_DIR" --parallel "$cores" --target cbor
  b1=$(date +%s.%N)
  echo "LAYER_B_SECONDS=$(elapsed "$b0" "$b1")"
fi

# --- compiler-cache stats --------------------------------------------------
case "${ABL_CXX_LAUNCHER:-}" in
  ccache)  ccache --show-stats ;;
  sccache) sccache --show-stats ;;
esac
