// SPDX-License-Identifier: MIT
// Typed offline HDR luminance conversion. No preset data or hardware access.
// Source/units/remaining integration: docs/O82-HDR-TONEMAP-REVIEW.md.
#ifndef UKE_O82_HDR_TONEMAP_H
#define UKE_O82_HDR_TONEMAP_H

#include <algorithm>
#include <array>
#include <bit>
#include <cfenv>
#include <cmath>
#include <cstddef>
#include <limits>
#include <span>

namespace o82 {
static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559 &&
              std::numeric_limits<float>::digits == 24);
inline constexpr std::size_t hdr_curve_limit = 17;
struct HdrLogCurve {
    // Base-10 logarithms of luminance in cd/m2; not encoded PQ sample values.
    std::array<float, hdr_curve_limit> source{}, panel{};
    std::size_t count = 0;
    bool operator==(const HdrLogCurve &) const = default;
};
struct HdrLuminanceRange { float black_nits = 0, white_nits = 0; };
enum class HdrCurveDirection { to_panel, to_source };
enum class HdrCurveError {
    none, size, nonfinite, order, range, direction, rounding_mode
};
namespace hdr_curve_detail {
inline float add(float a, float b) { volatile float out = a + b; return out; }
inline float subtract(float a, float b) { volatile float out = a - b; return out; }
inline float multiply(float a, float b) { volatile float out = a * b; return out; }
inline float divide(float a, float b) { volatile float out = a / b; return out; }
inline HdrCurveError validate(const HdrLogCurve &curve) {
    if (curve.count < 2 || curve.count > hdr_curve_limit) return HdrCurveError::size;
    for (std::size_t i = 0; i < curve.count; ++i) {
        if (!std::isfinite(curve.source[i]) || !std::isfinite(curve.panel[i]))
            return HdrCurveError::nonfinite;
        if (i && (curve.source[i] <= curve.source[i - 1] ||
                  curve.panel[i] < curve.panel[i - 1])) return HdrCurveError::order;
    }
    return HdrCurveError::none;
}
} // namespace hdr_curve_detail

inline HdrCurveError compile_hdr_log_curve(std::span<const float> source,
        std::span<const float> panel, HdrLogCurve &output) {
    if (source.size() != panel.size() || source.size() < 2 ||
        source.size() > hdr_curve_limit) return HdrCurveError::size;
    HdrLogCurve candidate;
    candidate.count = source.size();
    std::copy(source.begin(), source.end(), candidate.source.begin());
    std::copy(panel.begin(), panel.end(), candidate.panel.begin());
    const auto error = hdr_curve_detail::validate(candidate);
    if (error != HdrCurveError::none) return error;
    output = candidate;
    return HdrCurveError::none;
}

inline HdrCurveError map_hdr_log_luminance(const HdrLogCurve &curve, float value,
        HdrCurveDirection direction, float &output) {
    using namespace hdr_curve_detail;
    const auto error = validate(curve);
    if (error != HdrCurveError::none) return error;
    if (!std::isfinite(value)) return HdrCurveError::nonfinite;
    if (direction != HdrCurveDirection::to_panel &&
        direction != HdrCurveDirection::to_source) return HdrCurveError::direction;
    if (std::fegetround() != FE_TONEAREST) return HdrCurveError::rounding_mode;
    const bool inverse = direction == HdrCurveDirection::to_source;
    const auto &axis = inverse ? curve.panel : curve.source;
    const auto &result = inverse ? curve.source : curve.panel;
    // First matching knot defines a left generalized inverse on plateaus.
    // This also retains the first endpoint of a repeated terminal plateau.
    std::size_t low = 0, high = curve.count;
    while (low < high) {
        const auto middle = low + (high - low) / 2;
        if (axis[middle] < value) low = middle + 1;
        else high = middle;
    }
    if (!low) { output = result[0]; return HdrCurveError::none; }
    if (low == curve.count) {
        low--;
        while (low && axis[low] == axis[low - 1]) low--;
        output = result[low];
        return HdrCurveError::none;
    }
    if (axis[low] == value) { output = result[low]; return HdrCurveError::none; }
    const float width = subtract(axis[low], axis[low - 1]);
    const float offset = subtract(value, axis[low - 1]);
    if (!std::isfinite(width) || !std::isfinite(offset) || width <= 0)
        return HdrCurveError::range;
    const float fraction = divide(offset, width);
    const float upper = multiply(result[low], fraction);
    const float lower = multiply(result[low - 1], subtract(1.0f, fraction));
    const float candidate = add(upper, lower);
    if (!std::isfinite(candidate)) return HdrCurveError::range;
    output = candidate;
    return HdrCurveError::none;
}

// Forward input is absolute linear XYZ Y /10000; output is panel-relative Y.
// Inverse input is panel-relative Y; output is absolute linear XYZ Y /10000.
// Brightness/metadata policy supplies the range; this does not select it.
inline HdrCurveError map_hdr_normalized_luminance(const HdrLogCurve &curve,
        HdrLuminanceRange range, float value, HdrCurveDirection direction, float &output) {
    using namespace hdr_curve_detail;
    if (!std::isfinite(range.black_nits) || !std::isfinite(range.white_nits) ||
        !std::isfinite(value)) return HdrCurveError::nonfinite;
    if (range.black_nits < 0 || range.white_nits <= range.black_nits ||
        range.white_nits > 10000.0f) return HdrCurveError::range;
    const auto valid = validate(curve);
    if (valid != HdrCurveError::none) return valid;
    if (direction != HdrCurveDirection::to_panel &&
        direction != HdrCurveDirection::to_source) return HdrCurveError::direction;
    if (std::fegetround() != FE_TONEAREST) return HdrCurveError::rounding_mode;
    // Generic numeric floor in the inspected helper, not panel calibration.
    const float black = std::max(divide(range.black_nits, 10000.0f),
                                  std::bit_cast<float>(0x3356bf96u));
    const float span = subtract(divide(range.white_nits, 10000.0f), black);
    if (!std::isfinite(span) || span <= 0) return HdrCurveError::range;
    const bool inverse = direction == HdrCurveDirection::to_source;
    const float absolute = inverse ? add(multiply(span, value), black) : value;
    if (!std::isfinite(absolute)) return HdrCurveError::range;
    float mapped = black;
    if (absolute > 0) {
        const float nits = multiply(absolute, 10000.0f);
        if (!std::isfinite(nits)) return HdrCurveError::range;
        const float logarithm = std::log10(nits);
        float selected;
        const auto error = map_hdr_log_luminance(curve, logarithm, direction, selected);
        if (error != HdrCurveError::none) return error;
        mapped = divide(std::pow(10.0f, selected), 10000.0f);
    }
    const float candidate = inverse ? mapped :
        divide(std::max(subtract(mapped, black), 0.0f), span);
    if (!std::isfinite(candidate)) return HdrCurveError::range;
    output = candidate;
    return HdrCurveError::none;
}
} // namespace o82
#endif
