#pragma once
//
// kernels.cuh — host-callable interface to the CUDA kernels.
//
// This header contains NO CUDA syntax, only plain C++ declarations. main.cpp
// includes it and is compiled by the ordinary C++ compiler; only kernels.cu is
// compiled by nvcc. Building never needs a GPU — only running the GPU path does
// (verified separately on a GPU node via deploy/gpu-verify-job.yaml).
//
namespace cbor {

struct GpuResult {
    bool device_available = false;
    double vector_add_checksum = 0.0;
    double saxpy_checksum = 0.0;
    double matmul_checksum = 0.0;
};

// Runs every kernel on the GPU when a CUDA device is present. When none is
// available, returns {device_available = false} and the caller skips the check.
GpuResult run_gpu_kernels(int n, int dim);

// CPU reference implementations — the ground truth the GPU output is checked
// against. Same deterministic inputs as the GPU path.
double cpu_vector_add_checksum(int n);
double cpu_saxpy_checksum(int n);
double cpu_matmul_checksum(int dim);

}  // namespace cbor
