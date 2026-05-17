#pragma once
//
// common.hpp — deliberately heavy shared header.
//
// Every generated translation unit includes this, so the cost of parsing these
// expensive STL headers is paid ~N times in a baseline build. That is exactly
// what PCH (precompile once) and unity builds (parse once per batch) attack —
// this header is the surface those optimizations act on.
//
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <map>
#include <numeric>
#include <random>
#include <regex>      // the single most expensive STL header to compile
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace cbor {

// Non-trivial inline helpers — give PCH and unity builds real substance to
// amortize, not just header parsing.

inline double regex_score(const std::string& text) {
    static const std::regex token{R"(([A-Za-z]+)(\d*))"};
    double score = 0.0;
    for (auto it = std::sregex_iterator(text.begin(), text.end(), token);
         it != std::sregex_iterator(); ++it) {
        score += static_cast<double>((*it)[1].length());
    }
    return score;
}

inline double mix(double seed) {
    std::mt19937_64 rng{static_cast<std::uint64_t>(std::fabs(seed) * 1.0e6) + 1u};
    std::uniform_real_distribution<double> dist{0.0, 1.0};
    double acc = 0.0;
    for (int i = 0; i < 64; ++i) acc += dist(rng);
    return acc / 64.0;
}

}  // namespace cbor
