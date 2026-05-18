#
# BuildOptions.cmake — the build-optimization surface, in one file.
#
# Optimization flags are passed through CMake *presets* (see CMakePresets.json),
# never hard-coded here. Passing them via presets/CLI keeps CMakeLists.txt
# portable: a machine without ccache or mold simply configures with the
# `baseline` preset and nothing breaks.
#
# Preset-driven knobs (handled entirely by native CMake variables, no code):
#   compiler cache -> CMAKE_CXX_COMPILER_LAUNCHER / CMAKE_CUDA_COMPILER_LAUNCHER
#   mold linker    -> CMAKE_EXE_LINKER_FLAGS  = -fuse-ld=mold
#   split DWARF    -> CMAKE_CXX_FLAGS        += -gsplit-dwarf
#   unity build    -> CMAKE_UNITY_BUILD
#   Ninja job pools-> CMAKE_JOB_POOLS / CMAKE_JOB_POOL_COMPILE / CMAKE_JOB_POOL_LINK
#
# PCH is the one knob that needs a CMake command, so it is applied below and
# toggled natively by CMAKE_DISABLE_PRECOMPILE_HEADERS (baseline sets it ON).

# cbor_configure_target — apply the per-target optimization surface. Right now
# that is the precompiled header: no-op when the baseline preset sets
# CMAKE_DISABLE_PRECOMPILE_HEADERS=ON, restricted to C++ so nvcc is untouched.
# Called on the cbor executable and, when CBOR_SPLIT_LIBS=ON, on each module
# library — every target that compiles the heavy C++ TUs.
function(cbor_configure_target target)
    target_precompile_headers(${target} PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:${CMAKE_SOURCE_DIR}/src/core/include/common.hpp>")
endfunction()

# cbor_report_build_surface — print the active build-optimization knobs once,
# for the measurement logs. The knobs are target-independent, so this is kept
# separate from cbor_configure_target, which runs per target (17 times in a
# split build).
function(cbor_report_build_surface)
    message(STATUS "---- cbor build-optimization surface --------------")
    message(STATUS "  build type        : ${CMAKE_BUILD_TYPE}")
    message(STATUS "  generator         : ${CMAKE_GENERATOR}")
    message(STATUS "  C++ launcher      : ${CMAKE_CXX_COMPILER_LAUNCHER}")
    message(STATUS "  CUDA launcher     : ${CMAKE_CUDA_COMPILER_LAUNCHER}")
    message(STATUS "  unity build       : ${CMAKE_UNITY_BUILD}")
    message(STATUS "  PCH disabled      : ${CMAKE_DISABLE_PRECOMPILE_HEADERS}")
    message(STATUS "  split libraries   : ${CBOR_SPLIT_LIBS}")
    message(STATUS "  exe linker flags  : ${CMAKE_EXE_LINKER_FLAGS}")
    message(STATUS "  extra C++ flags   : ${CMAKE_CXX_FLAGS}")
    message(STATUS "---------------------------------------------------")
endfunction()
