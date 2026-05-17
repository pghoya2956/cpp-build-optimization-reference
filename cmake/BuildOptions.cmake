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

function(cbor_configure_target target)
    # Precompile the heavy shared header. No-op when the baseline preset sets
    # CMAKE_DISABLE_PRECOMPILE_HEADERS=ON. Restricted to C++ so nvcc is untouched.
    target_precompile_headers(${target} PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:${CMAKE_SOURCE_DIR}/src/core/include/common.hpp>")

    message(STATUS "---- cbor build-optimization surface --------------")
    message(STATUS "  build type        : ${CMAKE_BUILD_TYPE}")
    message(STATUS "  generator         : ${CMAKE_GENERATOR}")
    message(STATUS "  C++ launcher      : ${CMAKE_CXX_COMPILER_LAUNCHER}")
    message(STATUS "  CUDA launcher     : ${CMAKE_CUDA_COMPILER_LAUNCHER}")
    message(STATUS "  unity build       : ${CMAKE_UNITY_BUILD}")
    message(STATUS "  PCH disabled      : ${CMAKE_DISABLE_PRECOMPILE_HEADERS}")
    message(STATUS "  exe linker flags  : ${CMAKE_EXE_LINKER_FLAGS}")
    message(STATUS "  extra C++ flags   : ${CMAKE_CXX_FLAGS}")
    message(STATUS "---------------------------------------------------")
endfunction()
