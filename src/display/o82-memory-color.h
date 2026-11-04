// SPDX-License-Identifier: MIT
// Generic typed memory-color conversion; no preset data or hardware access.
// Provenance and integration limits: manifests/o82-memory-color-source-20261104.json.
#ifndef UKE_O82_MEMORY_COLOR_H
#define UKE_O82_MEMORY_COLOR_H

#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <limits>

namespace o82 {
static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559 &&
              std::numeric_limits<float>::digits == 24);
static_assert(sizeof(double) == 8 && std::numeric_limits<double>::is_iec559 &&
              std::numeric_limits<double>::digits == 53);

// Already typed PAMem conversion fields. This is not a JSON-to-PAMem mapping
// or the proprietary structure's binary ABI. It must not imply activation.
struct MemoryColorInput {
    std::int32_t hue_adjustment = 0, hue_extent = 0;
    float saturation_adjustment = 0, value_adjustment = 0;
    std::uint32_t saturation_extent = 0, value_extent = 0;
    std::uint32_t saturation_hold_control = 0, value_hold_control = 0;
    std::int32_t hue_minimum = 0, hue_maximum = 0;
    float saturation_minimum = 0, saturation_maximum = 0;
    float value_minimum = 0, value_maximum = 0;
};
struct MemoryColorData {
    std::uint32_t adjust_p0 = 0, adjust_p1 = 0, adjust_p2 = 0, blend_gain = 0;
    std::uint8_t saturation_hold = 0, value_hold = 0;
    std::uint32_t hue_region = 0, saturation_region = 0, value_region = 0;
    bool operator==(const MemoryColorData &) const = default;
};
enum class MemoryColorError { none, nonfinite, rounding_mode };

namespace memory_detail {
// Each OEM instruction rounds a separate binary32 result. A volatile boundary
// also prevents a caller's contraction setting from fusing multiply/add steps.
inline float add(float a, float b) { volatile float out = a + b; return out; }
inline float multiply(float a, float b) { volatile float out = a * b; return out; }
inline float divide(float a, float b) { volatile float out = a / b; return out; }
inline std::uint32_t percent(float value) {
    return static_cast<std::uint32_t>(divide(multiply(std::clamp(value, 0.0f, 100.0f),
                                                      255.0f), 100.0f));
}
inline std::uint32_t adjustment(float value, std::uint32_t hue_extent) {
    const float bounded = std::clamp(value, -100.0f, 100.0f);
    const float normalized = add(divide(add(bounded, 100.0f), 100.0f), -1.0f);
    const float scaled = divide(multiply(normalized, 262144.0f), float(hue_extent));
    // The OEM adds +0.5 before truncating for both signs. Symmetric rounding
    // would change negative coefficients, including the admitted lower bound.
    const auto result = static_cast<std::int32_t>(add(scaled, 0.5f));
    return std::uint32_t(std::clamp(result, -32768, 32767)) & 0xffffu;
}
inline std::uint32_t reciprocal(std::uint32_t value) {
    // This is rounded, unlike the SixZone integer reciprocal.
    return std::min(std::uint32_t(65536.0 / double(value) + 0.5), 32767u);
}
} // namespace memory_detail

inline MemoryColorError compile_memory_color(const MemoryColorInput &in, MemoryColorData &output) {
    for (const float value : {in.saturation_adjustment, in.value_adjustment,
                             in.saturation_minimum, in.saturation_maximum,
                             in.value_minimum, in.value_maximum})
        if (!std::isfinite(value)) return MemoryColorError::nonfinite;
    if (std::fegetround() != FE_TONEAREST) return MemoryColorError::rounding_mode;

    const auto h = std::clamp(in.hue_extent, std::int32_t(0), std::int32_t(360));
    const auto extent = std::max(std::uint32_t(h * 1536 / 360), 8u);
    const auto saturation = std::max(memory_detail::percent(float(in.saturation_extent)), 8u);
    const auto value = std::max(memory_detail::percent(float(in.value_extent)), 8u);
    const auto hue = std::clamp(in.hue_adjustment, std::int32_t(-180), std::int32_t(180));
    const auto hue_code = hue * 1536 / 360;
    const float ratio = float(double(hue_code) / double(extent));
    const auto hue_ratio = static_cast<std::int32_t>(std::round(memory_detail::multiply(ratio, 256.0f)));
    const auto region = [](std::int32_t angle) {
        if (angle < 0) angle += 360;
        return std::uint32_t(std::clamp(angle, std::int32_t(0), std::int32_t(360)) * 1536 / 360);
    };
    const auto hold = [](std::uint32_t control) -> std::uint8_t {
        return control < 3 ? std::uint8_t(3 - control) : 0;
    };
    MemoryColorData result;
    result.adjust_p0 = (extent & 0x7ffu) |
                      ((std::uint32_t(std::clamp(hue_ratio, -32768, 32767)) & 0xffffu) << 16);
    result.adjust_p1 = memory_detail::adjustment(in.saturation_adjustment, extent) |
                      (memory_detail::adjustment(in.value_adjustment, extent) << 16);
    result.adjust_p2 = memory_detail::reciprocal(saturation) |
                      (memory_detail::reciprocal(value) << 16);
    result.blend_gain = static_cast<std::uint32_t>(
        memory_detail::divide(2147483648.0f, float(extent * saturation * value)));
    result.saturation_hold = hold(in.saturation_hold_control);
    result.value_hold = hold(in.value_hold_control);
    // The parser's min/max keys establish the naming: minimum is the low
    // qualifier and maximum is the high qualifier, unlike the earlier inference
    // from unnamed proprietary input fields. Keep distinct endpoint fixtures.
    result.hue_region = region(in.hue_minimum) | (region(in.hue_maximum) << 16);
    result.saturation_region = memory_detail::percent(in.saturation_minimum) |
                              (memory_detail::percent(in.saturation_maximum) << 8) | (saturation << 16);
    result.value_region = memory_detail::percent(in.value_minimum) |
                         (memory_detail::percent(in.value_maximum) << 8) | (value << 16);
    output = result;
    return MemoryColorError::none;
}
} // namespace o82
#endif
