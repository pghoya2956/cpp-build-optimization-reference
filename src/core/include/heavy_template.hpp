#pragma once
//
// heavy_template.hpp — deliberately heavy, but memory-light, template metaprogramming.
//
// The per-TU build cost here is template *instantiation*: each generated TU
// materializes a large 2D grid of distinct Cell<I,J> types plus deep Polynomial
// chains. This is CPU-heavy and is exactly what unity builds and PCH amortize
// (they parse/instantiate a shared heavy header once instead of once per TU).
//
// It is kept memory-modest on purpose. An earlier design used a large constexpr
// loop as the heaviness knob; GCC's constexpr interpreter ballooned cc1plus to
// ~3.6 GB and OOM-killed the parallel baseline build, so the heaviness now comes
// from template instantiation, which is CPU-heavy but memory-light.
//
#include <cstddef>

namespace cbor {

// --- deep linear recursion: Polynomial<N> -> ... -> Polynomial<0> -----------
template <int N>
struct Polynomial {
    using Lower = Polynomial<N - 1>;
    static constexpr double coeff = 1.0 / (static_cast<double>(N) + 1.0);
    static double eval(double x) { return coeff + x * Lower::eval(x); }
};
template <>
struct Polynomial<0> {
    static constexpr double coeff = 1.0;
    static double eval(double) { return coeff; }
};

// --- compile-time value recursion ------------------------------------------
template <unsigned long long N>
struct MetaSum {
    static constexpr unsigned long long value = N + MetaSum<N - 1>::value;
};
template <>
struct MetaSum<0> {
    static constexpr unsigned long long value = 0;
};

// --- variadic pack expansion -----------------------------------------------
template <int... Is>
struct TypePack {
    static constexpr std::size_t size = sizeof...(Is);
    static constexpr double fold() {
        return (0.0 + ... + (1.0 / (static_cast<double>(Is) + 1.0)));
    }
};

// --- 2D template grid: the dominant per-TU build cost ----------------------
// Instantiating Grid<N>::value materializes (N+1)*(N+1) distinct Cell types.
// Each Cell is tiny, so memory stays modest; the cost is the instantiation
// machinery itself. The grid size N is the knob bench/gen-sources.sh tunes.
template <long I, long J>
struct Cell {
    using Prev = Cell<I, J - 1>;
    static constexpr long value =
        ((I * 2654435761L) ^ (J * 40503L) ^ (Prev::value * 31L)) & 0xffffffffL;
};
template <long I>
struct Cell<I, 0> {
    static constexpr long value = (I * 2654435761L) & 0xffffffffL;
};

template <long I, long J>
struct GridRow {
    static constexpr long value = Cell<I, J>::value ^ GridRow<I - 1, J>::value;
};
template <long J>
struct GridRow<0, J> {
    static constexpr long value = Cell<0, J>::value;
};

template <long N>
struct Grid {
    static constexpr long value = GridRow<N, N>::value;
};

}  // namespace cbor
