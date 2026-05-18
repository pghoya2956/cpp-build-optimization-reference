//
// main.cpp — single entry point exercising the CPU and GPU paths.
//
// Compiled by the ordinary C++ compiler (no CUDA syntax here). It sums every
// generated module, runs the CPU reference kernels, and — when a CUDA device
// is present — runs the GPU kernels and checks they agree with the CPU result.
//
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

#include "core/include/modules.gen.hpp"
#include "cuda/kernels.cuh"

namespace {

bool close_enough(double a, double b, double rtol = 1.0e-3) {
    const double denom = std::max(1.0, std::fabs(a));
    return std::fabs(a - b) / denom <= rtol;
}

}  // namespace

int main() {
    using namespace cbor;

    const double modules_total = compute_all_modules();
    std::cout << "[cpu] module aggregate = " << modules_total << '\n';

    const int n = 1 << 16;
    const int dim = 256;
    const double cpu_va = cpu_vector_add_checksum(n);
    const double cpu_sx = cpu_saxpy_checksum(n);
    const double cpu_mm = cpu_matmul_checksum(dim);
    std::cout << "[cpu] vector_add=" << cpu_va
              << " saxpy=" << cpu_sx
              << " matmul=" << cpu_mm << '\n';

    const GpuResult gpu = run_gpu_kernels(n, dim);
    if (!gpu.device_available) {
        std::cout << "[gpu] GPU path not exercised (see the [gpu] line above "
                     "for the reason) — build verified; run on a GPU node for "
                     "the runtime check\n";
        return EXIT_SUCCESS;
    }

    std::cout << "[gpu] vector_add=" << gpu.vector_add_checksum
              << " saxpy=" << gpu.saxpy_checksum
              << " matmul=" << gpu.matmul_checksum << '\n';

    const bool ok = close_enough(cpu_va, gpu.vector_add_checksum)
                 && close_enough(cpu_sx, gpu.saxpy_checksum)
                 && close_enough(cpu_mm, gpu.matmul_checksum);
    std::cout << (ok ? "[ok] CPU and GPU results agree\n"
                     : "[fail] CPU/GPU mismatch\n");
    return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
