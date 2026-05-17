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
include(cmake/generated_sources.cmake)   # defines CBOR_GENERATED_SOURCES

add_executable(cbor
    src/main.cpp
    src/cuda/kernels.cu
    ${CBOR_GENERATED_SOURCES})

target_include_directories(cbor PRIVATE
    src
    src/core/include)

cbor_configure_target(cbor)
