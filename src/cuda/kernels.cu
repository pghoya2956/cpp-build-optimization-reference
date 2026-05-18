#include "kernels.cuh"

#include <cstdio>
#include <vector>

#include <cuda_runtime.h>

namespace cbor {
namespace {

// ---- kernels --------------------------------------------------------------

__global__ void k_vector_add(const float* a, const float* b, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = a[i] + b[i];
}

__global__ void k_saxpy(float alpha, const float* x, float* y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = alpha * x[i] + y[i];
}

__global__ void k_matmul(const float* a, const float* b, float* c, int dim) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (row < dim && col < dim) {
        float acc = 0.0f;
        for (int k = 0; k < dim; ++k)
            acc += a[row * dim + k] * b[k * dim + col];
        c[row * dim + col] = acc;
    }
}

// ---- deterministic inputs (identical for the CPU and GPU paths) -----------

constexpr float kAlpha = 2.0f;

float in_a(int i) { return static_cast<float>(i) * 0.5f; }
float in_b(int i) { return static_cast<float>(i) * 0.25f; }
float mat_a(int idx) { return static_cast<float>(idx % 7) * 0.1f; }
float mat_b(int idx) { return static_cast<float>(idx % 5) * 0.1f; }

double sum(const std::vector<float>& v) {
    double s = 0.0;
    for (float x : v) s += static_cast<double>(x);
    return s;
}

}  // namespace

// ---- CPU reference --------------------------------------------------------

double cpu_vector_add_checksum(int n) {
    std::vector<float> out(n);
    for (int i = 0; i < n; ++i) out[i] = in_a(i) + in_b(i);
    return sum(out);
}

double cpu_saxpy_checksum(int n) {
    std::vector<float> y(n);
    for (int i = 0; i < n; ++i) y[i] = kAlpha * in_a(i) + in_b(i);
    return sum(y);
}

double cpu_matmul_checksum(int dim) {
    std::vector<float> a(dim * dim), b(dim * dim), c(dim * dim, 0.0f);
    for (int i = 0; i < dim * dim; ++i) { a[i] = mat_a(i); b[i] = mat_b(i); }
    for (int r = 0; r < dim; ++r)
        for (int col = 0; col < dim; ++col) {
            float acc = 0.0f;
            for (int k = 0; k < dim; ++k)
                acc += a[r * dim + k] * b[k * dim + col];
            c[r * dim + col] = acc;
        }
    return sum(c);
}

// ---- GPU path -------------------------------------------------------------

#define CBOR_CUDA_OK(expr)                                          \
    do {                                                            \
        cudaError_t _e = (expr);                                    \
        if (_e != cudaSuccess) {                                    \
            std::fprintf(stderr, "[cuda] %s: %s\n", #expr,          \
                         cudaGetErrorString(_e));                   \
            return result;                                          \
        }                                                           \
    } while (0)

GpuResult run_gpu_kernels(int n, int dim) {
    GpuResult result;

    // --- device discovery --------------------------------------------------
    // The log must not conflate two outcomes: a clean "no usable device" (a
    // CPU-only run — no GPU requested, or no driver in this container) versus
    // a CUDA *error* on a node that does have a GPU (a driver/runtime mismatch,
    // the historic error 804). The previous code collapsed both into one "no
    // device" message; here each prints its own line so the Job log states
    // exactly why the GPU path did not run.
    int device_count = 0;
    cudaError_t status = cudaGetDeviceCount(&device_count);

    // cudaGetDeviceCount signals "nothing to run on" three ways: success with a
    // zero count, cudaErrorNoDevice, or cudaErrorInsufficientDriver (no driver
    // injected — the deploy/cpu-contrast-job.yaml case).
    const bool no_device = (status == cudaSuccess && device_count == 0)
                        || status == cudaErrorNoDevice
                        || status == cudaErrorInsufficientDriver;
    if (no_device) {
        std::printf("[gpu] no usable CUDA device — CPU-only run, GPU path "
                    "skipped (cudaGetDeviceCount: %s)\n",
                    cudaGetErrorString(status));
        result.device_available = false;
        return result;
    }
    if (status != cudaSuccess) {
        std::printf("[gpu] cudaGetDeviceCount failed: %s (error %d) — a CUDA "
                    "error on a node that has a GPU, not an absent device; "
                    "the GPU path could not run\n",
                    cudaGetErrorString(status), static_cast<int>(status));
        result.device_available = false;
        return result;
    }
    result.device_available = true;

    // --- device identification ---------------------------------------------
    int driver_version = 0, runtime_version = 0;
    cudaDriverGetVersion(&driver_version);
    cudaRuntimeGetVersion(&runtime_version);
    std::printf("[gpu] %d CUDA device(s) | driver %d.%d | runtime %d.%d\n",
                device_count,
                driver_version / 1000, (driver_version % 1000) / 10,
                runtime_version / 1000, (runtime_version % 1000) / 10);

    cudaDeviceProp prop;
    if (cudaGetDeviceProperties(&prop, 0) == cudaSuccess) {
        std::printf("[gpu] device 0: %s | compute capability %d.%d | "
                    "%d SMs | %.1f GiB global memory\n",
                    prop.name, prop.major, prop.minor,
                    prop.multiProcessorCount,
                    static_cast<double>(prop.totalGlobalMem)
                        / (1024.0 * 1024.0 * 1024.0));
    }

    const int threads = 256;
    const int blocks = (n + threads - 1) / threads;

    // vector_add and saxpy share the same a / b input vectors.
    std::vector<float> h_a(n), h_b(n), h_out(n);
    for (int i = 0; i < n; ++i) { h_a[i] = in_a(i); h_b[i] = in_b(i); }

    float *d_a = nullptr, *d_b = nullptr, *d_out = nullptr;
    CBOR_CUDA_OK(cudaMalloc(&d_a, n * sizeof(float)));
    CBOR_CUDA_OK(cudaMalloc(&d_b, n * sizeof(float)));
    CBOR_CUDA_OK(cudaMalloc(&d_out, n * sizeof(float)));
    CBOR_CUDA_OK(cudaMemcpy(d_a, h_a.data(), n * sizeof(float), cudaMemcpyHostToDevice));
    CBOR_CUDA_OK(cudaMemcpy(d_b, h_b.data(), n * sizeof(float), cudaMemcpyHostToDevice));

    std::printf("[gpu] launching k_vector_add <<<%d blocks, %d threads>>> "
                "on device 0\n", blocks, threads);
    k_vector_add<<<blocks, threads>>>(d_a, d_b, d_out, n);
    CBOR_CUDA_OK(cudaGetLastError());
    CBOR_CUDA_OK(cudaDeviceSynchronize());
    std::printf("[gpu] k_vector_add executed on device 0\n");
    CBOR_CUDA_OK(cudaMemcpy(h_out.data(), d_out, n * sizeof(float), cudaMemcpyDeviceToHost));
    result.vector_add_checksum = sum(h_out);

    // saxpy: y starts as b, becomes alpha*a + b in place.
    CBOR_CUDA_OK(cudaMemcpy(d_out, h_b.data(), n * sizeof(float), cudaMemcpyHostToDevice));
    std::printf("[gpu] launching k_saxpy <<<%d blocks, %d threads>>> "
                "on device 0\n", blocks, threads);
    k_saxpy<<<blocks, threads>>>(kAlpha, d_a, d_out, n);
    CBOR_CUDA_OK(cudaGetLastError());
    CBOR_CUDA_OK(cudaDeviceSynchronize());
    std::printf("[gpu] k_saxpy executed on device 0\n");
    CBOR_CUDA_OK(cudaMemcpy(h_out.data(), d_out, n * sizeof(float), cudaMemcpyDeviceToHost));
    result.saxpy_checksum = sum(h_out);

    cudaFree(d_a);
    cudaFree(d_b);
    cudaFree(d_out);

    // matmul
    std::vector<float> h_ma(dim * dim), h_mb(dim * dim), h_mc(dim * dim);
    for (int i = 0; i < dim * dim; ++i) { h_ma[i] = mat_a(i); h_mb[i] = mat_b(i); }

    float *d_ma = nullptr, *d_mb = nullptr, *d_mc = nullptr;
    CBOR_CUDA_OK(cudaMalloc(&d_ma, dim * dim * sizeof(float)));
    CBOR_CUDA_OK(cudaMalloc(&d_mb, dim * dim * sizeof(float)));
    CBOR_CUDA_OK(cudaMalloc(&d_mc, dim * dim * sizeof(float)));
    CBOR_CUDA_OK(cudaMemcpy(d_ma, h_ma.data(), dim * dim * sizeof(float), cudaMemcpyHostToDevice));
    CBOR_CUDA_OK(cudaMemcpy(d_mb, h_mb.data(), dim * dim * sizeof(float), cudaMemcpyHostToDevice));

    dim3 block(16, 16);
    dim3 grid((dim + 15) / 16, (dim + 15) / 16);
    std::printf("[gpu] launching k_matmul <<<grid %dx%d, block 16x16>>> "
                "on device 0\n",
                static_cast<int>(grid.x), static_cast<int>(grid.y));
    k_matmul<<<grid, block>>>(d_ma, d_mb, d_mc, dim);
    CBOR_CUDA_OK(cudaGetLastError());
    CBOR_CUDA_OK(cudaDeviceSynchronize());
    std::printf("[gpu] k_matmul executed on device 0\n");
    CBOR_CUDA_OK(cudaMemcpy(h_mc.data(), d_mc, dim * dim * sizeof(float), cudaMemcpyDeviceToHost));
    result.matmul_checksum = sum(h_mc);

    cudaFree(d_ma);
    cudaFree(d_mb);
    cudaFree(d_mc);
    return result;
}

#undef CBOR_CUDA_OK

}  // namespace cbor
