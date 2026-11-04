// SPDX-License-Identifier: MIT
// SixZone 2.0 protocol conversion; no preset coefficients or register access.
// Provenance and ABI limits: manifests/o82-sixzone-source-20261104.json.
#ifndef UKE_O82_SIXZONE_H
#define UKE_O82_SIXZONE_H

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <span>

namespace o82 {
inline constexpr std::size_t sixzone_samples = 384;
enum class Edge : std::uint8_t { slope, step };
struct Range {
    int minimum = 0, maximum = 0;
};
struct SixZoneThresholds {
    Range saturation, value;
    int saturation_offset = 0, value_offset = 0;
    std::array<Edge, 2> saturation_edges{Edge::slope, Edge::slope};
    std::array<Edge, 2> value_edges{Edge::slope, Edge::slope};
    // A parser must distinguish wholly absent legacy bands from partial input.
    std::optional<std::array<Range, 3>> saturation_bands;
    bool sv_enable = false;
};
struct SixZoneInput {
    SixZoneThresholds thresholds;
    std::span<const std::uint16_t> hue, saturation, value;
    // Empty additional curves select the ordinary saturation curve, as in OEM.
    std::span<const std::uint16_t> saturation_middle, saturation_high;
};
struct SixZoneData {
    // Exact extended UAPI bits: hue/saturation/value, optionally SV.
    std::uint32_t flags = 0, threshold = 0, adjust_p0 = 0, adjust_p1 = 0;
    std::uint32_t saturation_adjust_p0 = 0, saturation_adjust_p1 = 0;
    std::uint8_t saturation_hold = 0, value_hold = 0;
    std::array<std::uint32_t, sixzone_samples> curve_p0{}, curve_p1{}, curve_p2{};
    bool operator==(const SixZoneData &) const = default;
};
enum class SixZoneError { none, curve_length, curve_sample, threshold, edge, bands };

// For the admitted integer percent domain, this equals the OEM's single-
// precision clamp/multiply255/divide100/truncate operation. No fractional
// threshold or implicit unit conversion is admitted by this typed interface.
constexpr std::uint32_t sixzone_quantize(unsigned value) {
    return std::min(value, 100u) * 255u / 100u;
}
constexpr std::uint32_t sixzone_reciprocal(std::uint32_t value) {
    return value ? std::min(65536u / value, 32767u) : 0u;
}
inline SixZoneError compile_sixzone(const SixZoneInput &input, SixZoneData &output) {
    const auto middle = input.saturation_middle.empty() ? input.saturation : input.saturation_middle;
    const auto high = input.saturation_high.empty() ? input.saturation : input.saturation_high;
    for (const auto curve : {input.hue, input.saturation, input.value, middle, high}) {
        if (curve.size() != sixzone_samples) return SixZoneError::curve_length;
        if (std::any_of(curve.begin(), curve.end(), [](auto value) { return value > 4095; }))
            return SixZoneError::curve_sample;
    }
    const auto percent = [](int value) { return value >= 0 && value <= 100; };
    const auto range = [&](Range value) {
        return percent(value.minimum) && percent(value.maximum) && value.minimum <= value.maximum;
    };
    const auto &t = input.thresholds;
    if (!range(t.saturation) || !range(t.value) ||
        !percent(t.saturation_offset) || !percent(t.value_offset)) return SixZoneError::threshold;
    for (const auto edges : {t.saturation_edges, t.value_edges})
        for (const auto edge : edges)
            if (edge != Edge::slope && edge != Edge::step) return SixZoneError::edge;
    // Standard JSON null-to-zero semantics supply legacy band endpoints.
    const auto bands = t.saturation_bands.value_or(std::array<Range, 3>{});
    for (const auto band : bands)
        if (!range(band)) return SixZoneError::bands;
    if (bands[0].maximum > bands[1].minimum || bands[1].maximum > bands[2].minimum)
        return SixZoneError::bands;

    const auto q = [](int value) { return sixzone_quantize(static_cast<unsigned>(value)); };
    const auto hold = [](std::array<Edge, 2> edges, std::uint32_t offset) -> std::uint8_t {
        if (!offset) return 3;
        return (edges[0] == Edge::step ? 1 : 0) | (edges[1] == Edge::step ? 2 : 0);
    };
    const auto sat_offset = q(t.saturation_offset), val_offset = q(t.value_offset);
    const auto lower_gap = bands[1].minimum - bands[0].maximum;
    const auto upper_gap = bands[2].minimum - bands[1].maximum;
    const auto lower_center = bands[0].maximum + lower_gap / 2;
    const auto upper_center = bands[1].maximum + upper_gap / 2;
    SixZoneData result;
    result.flags = 7u | (t.sv_enable ? 8u : 0u);
    result.threshold = q(t.saturation.minimum) | (q(t.value.minimum) << 8) |
                       (q(t.value.maximum) << 16) | (q(t.saturation.maximum) << 24);
    result.adjust_p0 = sat_offset | (val_offset << 8);
    result.adjust_p1 = sixzone_reciprocal(sat_offset) | (sixzone_reciprocal(val_offset) << 16);
    result.saturation_hold = hold(t.saturation_edges, sat_offset);
    result.value_hold = hold(t.value_edges, val_offset);
    result.saturation_adjust_p0 = q(lower_center) | (q(upper_center) << 8) |
                                 (q(lower_gap) << 16) | (q(upper_gap) << 24);
    result.saturation_adjust_p1 = sixzone_reciprocal(q(lower_gap)) |
                                 (sixzone_reciprocal(q(upper_gap)) << 16);
    for (std::size_t i = 0; i < sixzone_samples; ++i) {
        result.curve_p0[i] = input.hue[i];
        result.curve_p1[i] = (std::uint32_t(input.saturation[i]) << 16) | input.value[i];
        result.curve_p2[i] = middle[i] | (std::uint32_t(high[i]) << 16);
    }
    // Refusal leaves every caller-owned word unchanged.
    output = result;
    return SixZoneError::none;
}
} // namespace o82
#endif
