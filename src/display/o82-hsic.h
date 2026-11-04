// SPDX-License-Identifier: MIT
// Typed HSIC1.7 protocol conversion; no preset data or register access.
// Provenance and integration limits: manifests/o82-hsic-source-20261104.json.
#ifndef UKE_O82_HSIC_H
#define UKE_O82_HSIC_H

#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <limits>

namespace o82 {
static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559 &&
              std::numeric_limits<float>::digits == 24);
struct HsicInput {
    std::int32_t hue = 0;
    float saturation = 0, value = 0, contrast = 0, saturation_threshold = 0;
};
struct HsicData {
    std::uint32_t hue = 0, saturation = 0, value = 0, contrast = 0;
    // The JSON parser derives this from typed inputs, before quantization.
    bool enabled = false;
    bool operator==(const HsicData &) const = default;
};
enum class HsicError { none, nonfinite, rounding_mode };

// Preserve the two single-precision operations and truncation toward zero.
// These are generic protocol scales, not SixZone percentages or S4.9 values.
inline HsicError compile_hsic(const HsicInput &input, HsicData &output) {
    if (!std::isfinite(input.saturation) || !std::isfinite(input.value) ||
        !std::isfinite(input.contrast) || !std::isfinite(input.saturation_threshold))
        return HsicError::nonfinite;
    if (std::fegetround() != FE_TONEAREST) return HsicError::rounding_mode;
    const auto adjustment = [](float value, float bound) {
        const float product = std::clamp(value, -bound, bound) * 65.0f;
        const float scaled = product / bound;
        return static_cast<std::uint32_t>(static_cast<std::int32_t>(scaled)) & 0xffu;
    };
    HsicData candidate;
    const auto hue = std::clamp(input.hue, std::int32_t(-180), std::int32_t(180));
    candidate.hue = static_cast<std::uint32_t>(hue * 768 / 180) & 0xfffu;
    candidate.saturation = adjustment(input.saturation, 1.0f);
    const float threshold = std::clamp(input.saturation_threshold, 0.0f, 1.0f) * 255.0f;
    candidate.saturation |= (static_cast<std::uint32_t>(threshold) & 0xffu) << 8;
    candidate.value = adjustment(input.value, 255.0f);
    candidate.contrast = adjustment(input.contrast, 1.0f);
    candidate.enabled = input.hue != 0 || input.saturation != 0 || input.value != 0 ||
                        input.contrast != 0 || input.saturation_threshold != 0;
    output = candidate;
    return HsicError::none;
}
} // namespace o82
#endif
