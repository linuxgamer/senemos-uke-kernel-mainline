// SPDX-License-Identifier: MIT
// Synthetic protocol inputs only; no private data or hardware access.
#include "o82-sixzone.h"
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {
unsigned checks;
void check(bool value) {
    ++checks;
    if (!value) {
        std::cerr << "SixZone protocol failure at check " << checks << '\n';
        std::exit(1);
    }
}
using namespace o82;
using Curve = std::array<std::uint16_t, sixzone_samples>;
struct Fixture {
    Curve hue{}, saturation{}, value{}, middle{}, high{};
    SixZoneInput input;
    Fixture() {
        for (unsigned i = 0; i < sixzone_samples; ++i) {
            hue[i] = (i * 7 + 3) % 4096;
            saturation[i] = (i * 13 + 29) % 4096;
            value[i] = (i * 19 + 47) % 4096;
            middle[i] = (i * 23 + 71) % 4096;
            high[i] = (i * 31 + 97) % 4096;
        }
        input.hue = hue; input.saturation = saturation; input.value = value;
        input.saturation_middle = middle; input.saturation_high = high;
        input.thresholds.saturation = {10, 90}; input.thresholds.value = {20, 80};
        input.thresholds.saturation_offset = 5; input.thresholds.value_offset = 9;
        input.thresholds.saturation_edges = {Edge::step, Edge::slope};
        input.thresholds.value_edges = {Edge::slope, Edge::step};
        input.thresholds.saturation_bands = std::array<Range, 3>{{{0, 10}, {31, 50}, {73, 100}}};
        input.thresholds.sv_enable = true;
    }
};
unsigned reference_percent(int value) {
    // Independent floating-point formulation of the traced OEM operation.
    float bounded = std::clamp(static_cast<float>(value), 0.0f, 100.0f);
    return static_cast<unsigned>((bounded * 255.0f) / 100.0f);
}
void numeric_domain() {
    for (unsigned i = 0; i <= 100; ++i) {
        check(sixzone_quantize(i) == reference_percent(i));
        check(sixzone_quantize(i) == static_cast<unsigned>(std::floor(i * 2.55 + 1e-9)));
    }
    check(sixzone_quantize(101) == 255);
    check(sixzone_quantize(0xffffffffu) == 255);
    check(sixzone_reciprocal(0) == 0);
    for (unsigned i = 1; i <= 255; ++i) {
        const auto r = sixzone_reciprocal(i);
        check(r <= 32767);
        if (r == 32767) check(i <= 2);
        else {
            check(r * i <= 65536);
            check((r + 1) * i > 65536);
        }
    }
}
void packed_state() {
    Fixture f;
    SixZoneData out;
    check(compile_sixzone(f.input, out) == SixZoneError::none);
    // Hand-calculated bytes deliberately distinguish every field and odd gap.
    check(out.flags == 15);
    check(out.threshold == 0xe5cc3319u);
    check(out.adjust_p0 == 0x160cu);
    check(out.adjust_p1 == 0x0ba21555u);
    check(out.saturation_hold == 1 && out.value_hold == 2);
    check(out.saturation_adjust_p0 == 0x3a359b33u);
    check(out.saturation_adjust_p1 == 0x046904d4u);
    for (unsigned i = 0; i < sixzone_samples; ++i) {
        check(out.curve_p0[i] == f.hue[i]);
        check((out.curve_p1[i] >> 16) == f.saturation[i]);
        check((out.curve_p1[i] & 0xffff) == f.value[i]);
        check((out.curve_p2[i] & 0xffff) == f.middle[i]);
        check((out.curve_p2[i] >> 16) == f.high[i]);
    }
    f.input.saturation_middle = {};
    check(compile_sixzone(f.input, out) == SixZoneError::none);
    for (unsigned i = 0; i < sixzone_samples; ++i) {
        check((out.curve_p2[i] & 0xffff) == f.saturation[i]);
        check((out.curve_p2[i] >> 16) == f.high[i]);
    }
    f.input.saturation_middle = f.middle;
    f.input.saturation_high = {};
    check(compile_sixzone(f.input, out) == SixZoneError::none);
    for (unsigned i = 0; i < sixzone_samples; ++i) {
        check((out.curve_p2[i] & 0xffff) == f.middle[i]);
        check((out.curve_p2[i] >> 16) == f.saturation[i]);
    }
    f.input.saturation_middle = {};
    f.input.thresholds.saturation_bands.reset();
    f.input.thresholds.sv_enable = false;
    check(compile_sixzone(f.input, out) == SixZoneError::none);
    check(out.flags == 7 && out.saturation_adjust_p0 == 0 && out.saturation_adjust_p1 == 0);
    for (unsigned i = 0; i < sixzone_samples; ++i) {
        check(out.curve_p0[i] == f.hue[i]);
        check(out.curve_p2[i] == ((std::uint32_t(f.saturation[i]) << 16) | f.saturation[i]));
    }
    // Exercise every 12-bit component value at asymmetric positions.
    for (unsigned base = 0; base < 4096; base += sixzone_samples) {
        for (unsigned i = 0; i < sixzone_samples; ++i) f.hue[i] = (base + i) % 4096;
        check(compile_sixzone(f.input, out) == SixZoneError::none);
        for (unsigned i = 0; i < sixzone_samples; ++i) check(out.curve_p0[i] == f.hue[i]);
    }
}
void bands_and_holds() {
    Fixture f;
    SixZoneData out;
    for (unsigned sat_edge = 0; sat_edge < 4; ++sat_edge)
        for (unsigned val_edge = 0; val_edge < 4; ++val_edge)
            for (unsigned zero = 0; zero < 4; ++zero) {
                auto &t = f.input.thresholds;
                t.saturation_edges = {sat_edge & 1 ? Edge::step : Edge::slope,
                                      sat_edge & 2 ? Edge::step : Edge::slope};
                t.value_edges = {val_edge & 1 ? Edge::step : Edge::slope,
                                 val_edge & 2 ? Edge::step : Edge::slope};
                t.saturation_offset = zero & 1 ? 0 : 5;
                t.value_offset = zero & 2 ? 0 : 9;
                check(compile_sixzone(f.input, out) == SixZoneError::none);
                check(out.saturation_hold == (zero & 1 ? 3 : sat_edge));
                check(out.value_hold == (zero & 2 ? 3 : val_edge));
            }
    for (int left = 0; left <= 100; ++left)
        for (int gap = 0; left + gap <= 100; ++gap) {
            f.input.thresholds.saturation_bands =
                std::array<Range, 3>{{{0, left}, {left + gap, left + gap}, {100, 100}}};
            check(compile_sixzone(f.input, out) == SixZoneError::none);
            const int upper = 100 - left - gap;
            const unsigned lc = reference_percent(left + gap / 2);
            const unsigned uc = reference_percent(left + gap + upper / 2);
            const unsigned lq = reference_percent(gap), uq = reference_percent(upper);
            check(out.saturation_adjust_p0 == (lc | (uc << 8) | (lq << 16) | (uq << 24)));
            const unsigned lr = lq ? std::min(32767u, 65536u / lq) : 0;
            const unsigned ur = uq ? std::min(32767u, 65536u / uq) : 0;
            check(out.saturation_adjust_p1 == (lr | (ur << 16)));
        }
}
void refusals() {
    Fixture f;
    SixZoneData out;
    check(compile_sixzone(f.input, out) == SixZoneError::none);
    const auto preserved = out;
    const auto reject = [&](SixZoneError expected) {
        check(compile_sixzone(f.input, out) == expected);
        check(out == preserved);
    };
    for (auto member : {&SixZoneInput::hue, &SixZoneInput::saturation, &SixZoneInput::value,
                        &SixZoneInput::saturation_middle, &SixZoneInput::saturation_high}) {
        const auto original = f.input.*member;
        f.input.*member = original.first(383);
        reject(SixZoneError::curve_length);
        f.input.*member = original;
    }
    for (auto *curve : {&f.hue, &f.saturation, &f.value, &f.middle, &f.high}) {
        const auto saved = (*curve)[57];
        (*curve)[57] = 4096; reject(SixZoneError::curve_sample);
        (*curve)[57] = saved;
    }
    const auto original = f.input.thresholds;
    for (auto member : {&SixZoneThresholds::saturation_offset, &SixZoneThresholds::value_offset}) {
        for (const int value : {-1, 101}) {
            f.input.thresholds.*member = value; reject(SixZoneError::threshold);
        }
        f.input.thresholds = original;
    }
    for (auto member : {&SixZoneThresholds::saturation, &SixZoneThresholds::value}) {
        for (const auto range : {Range{-1, 50}, Range{0, 101}, Range{60, 50}}) {
            f.input.thresholds.*member = range; reject(SixZoneError::threshold);
        }
        f.input.thresholds = original;
    }
    for (auto member : {&SixZoneThresholds::saturation_edges, &SixZoneThresholds::value_edges}) {
        for (unsigned index = 0; index < 2; ++index) {
            (f.input.thresholds.*member)[index] = static_cast<Edge>(2);
            reject(SixZoneError::edge); f.input.thresholds = original;
        }
    }
    for (unsigned index = 0; index < 3; ++index)
        for (const auto range : {Range{-1, 10}, Range{0, 101}, Range{20, 10}}) {
            (*f.input.thresholds.saturation_bands)[index] = range;
            reject(SixZoneError::bands); f.input.thresholds = original;
        }
    (*f.input.thresholds.saturation_bands)[0].maximum = 32;
    reject(SixZoneError::bands); f.input.thresholds = original;
    (*f.input.thresholds.saturation_bands)[1].maximum = 74;
    reject(SixZoneError::bands);
}
} // namespace
int main() {
    numeric_domain(); packed_state(); bands_and_holds(); refusals();
    std::cout << "SixZone 2.0 converter: " << checks
              << " synthetic quantization, packing, legacy, hold and refusal checks passed; no hardware result\n";
}
