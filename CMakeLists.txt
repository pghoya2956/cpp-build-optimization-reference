cmake_minimum_required(VERSION 3.21)

# CUDA architecture 86 = compute capability 8.6 (the GPU used for runtime
# verification). Override for other GPUs or CI. Must be set before project() so
# it initializes the CUDA language.
set(CMAKE_CUDA_ARCHITECTURES "86" CACHE STRING "Target CUDA compute capabilities")

project(cpp_build_optimization_reference
        VERSION 0.1.0
        DESCRIPTION "Before/after reference for C++/CUDA container build optimization"
        LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
endif()

include(cmake/BuildOptions.cmake)
include(cmake/generated_sources.cmake)   # defines CBOR_GENERATED_SOURCES (96 TUs)

# CBOR_SPLIT_LIBS — a measurement-only build-graph variant (see
# docs/measurement-methodology.md, "다중 링크 타깃 변형"). It controls how the 96
# generated TUs are grouped, without touching the TUs themselves:
#   none    the TUs link straight into the cbor executable — one ld link step.
#   static  CBOR_SPLIT_LIB_COUNT static libraries  — N ar steps + one ld link.
#   shared  CBOR_SPLIT_LIB_COUNT shared libraries   — N ld links + one ld link.
# This is how the mold linker's contribution is measured against link-target
# count: mold accelerates ld, not ar, so only the shared variant multiplies its
# work. The TUs, their behaviour and the final binary are identical across all
# three — only the link granularity changes.
set(CBOR_SPLIT_LIBS "none" CACHE STRING "TU grouping: none | static | shared (measurement variant)")
set_property(CACHE CBOR_SPLIT_LIBS PROPERTY STRINGS none static shared)
set(CBOR_SPLIT_LIB_COUNT 16 CACHE STRING "Library count when CBOR_SPLIT_LIBS is static or shared")

if(NOT CBOR_SPLIT_LIBS MATCHES "^(none|static|shared)$")
    message(FATAL_ERROR "CBOR_SPLIT_LIBS must be none, static or shared (got: ${CBOR_SPLIT_LIBS})")
endif()

add_executable(cbor src/main.cpp src/cuda/kernels.cu)
target_include_directories(cbor PRIVATE src src/core/include)

if(CBOR_SPLIT_LIBS STREQUAL "none")
    # Default — the generated TUs compile straight into the executable.
    target_sources(cbor PRIVATE ${CBOR_GENERATED_SOURCES})
else()
    # Chunk the generated TUs into CBOR_SPLIT_LIB_COUNT libraries of roughly
    # equal size. list(SUBLIST) clamps the final chunk, so a count that does not
    # divide the TU total evenly is still safe. STATIC uses ar; SHARED uses ld,
    # so the shared variant is the one that multiplies the mold linker's work.
    string(TOUPPER "${CBOR_SPLIT_LIBS}" _cbor_lib_kind)   # STATIC or SHARED
    list(LENGTH CBOR_GENERATED_SOURCES _cbor_tu_total)
    math(EXPR _cbor_chunk
         "(${_cbor_tu_total} + ${CBOR_SPLIT_LIB_COUNT} - 1) / ${CBOR_SPLIT_LIB_COUNT}")
    math(EXPR _cbor_last_lib "${CBOR_SPLIT_LIB_COUNT} - 1")
    foreach(_i RANGE ${_cbor_last_lib})
        math(EXPR _cbor_start "${_i} * ${_cbor_chunk}")
        if(_cbor_start GREATER_EQUAL _cbor_tu_total)
            break()
        endif()
        list(SUBLIST CBOR_GENERATED_SOURCES ${_cbor_start} ${_cbor_chunk} _cbor_group)
        if(_i LESS 10)
            set(_cbor_lib "cbor_mod_0${_i}")
        else()
            set(_cbor_lib "cbor_mod_${_i}")
        endif()
        add_library(${_cbor_lib} ${_cbor_lib_kind} ${_cbor_group})
        target_include_directories(${_cbor_lib} PRIVATE src src/core/include)
        cbor_configure_target(${_cbor_lib})
        target_link_libraries(cbor PRIVATE ${_cbor_lib})
    endforeach()
endif()

cbor_configure_target(cbor)
cbor_report_build_surface()
