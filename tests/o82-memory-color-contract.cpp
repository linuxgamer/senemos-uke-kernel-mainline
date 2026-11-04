// SPDX-License-Identifier: MIT
// Synthetic protocol inputs; integer IEEE754 oracle, no vendor execution.
#include "o82-memory-color.h"

#include <array>
#include <bit>
#include <cassert>
#include <climits>
#include <cstdio>

namespace {
using Wide = unsigned __int128;
struct Binary { bool negative = false; std::uint64_t mantissa = 0; int power = 0; };
unsigned bits(Wide value) { unsigned n = 0; while (value) { value >>= 1; ++n; } return n; }
Binary integer(std::int64_t value) {
    return {value < 0, value < 0 ? std::uint64_t(-value) : std::uint64_t(value), 0};
}
Binary raw_float(std::uint32_t raw) {
    const auto exponent = (raw >> 23) & 255;
    assert(exponent != 255);
    return {bool(raw >> 31), (raw & 0x7fffff) | (exponent ? 0x800000u : 0),
            exponent ? int(exponent) - 150 : -149};
}
// Independently round a rational times a power of two to binary32/binary64.
// No floating-point arithmetic supplies any oracle result.
Binary rounded(bool negative, Wide numerator, Wide denominator, int power,
               unsigned precision = 24) {
    assert(denominator && (precision == 24 || precision == 53));
    if (!numerator) return {};
    int order = int(bits(numerator)) - int(bits(denominator));
    if (order >= 0 ? numerator < (denominator << order) :
                     (numerator << -order) < denominator) --order;
    const int minimum_power = precision == 24 ? -149 : -1074;
    int result_power = std::max(order + power - int(precision) + 1, minimum_power);
    const int shift = power - result_power;
    if (shift >= 0) {
        assert(bits(numerator) + shift <= 127);
        numerator <<= shift;
    } else {
        // An input much smaller than half of the smallest subnormal rounds0.
        if (bits(denominator) + unsigned(-shift) > 127) return {};
        denominator <<= -shift;
    }
    auto quotient = numerator / denominator, remainder = numerator % denominator;
    quotient += remainder > denominator / 2 ||
                (!(denominator & 1) && remainder == denominator / 2 && (quotient & 1));
    if (quotient == (Wide(1) << precision)) { quotient >>= 1; ++result_power; }
    assert(quotient < (Wide(1) << precision));
    return {negative, std::uint64_t(quotient), result_power};
}
Binary convert(Binary in, unsigned precision = 24) {
    return rounded(in.negative, in.mantissa, 1, in.power, precision);
}
Binary plus(Binary a, Binary b, unsigned precision = 24) {
    if (!a.mantissa) return convert(b, precision);
    if (!b.mantissa) return convert(a, precision);
    if (std::abs(a.power - b.power) > 100) return convert(a.power > b.power ? a : b, precision);
    const int power = std::min(a.power, b.power);
    assert(bits(a.mantissa) + unsigned(a.power - power) <= 127);
    assert(bits(b.mantissa) + unsigned(b.power - power) <= 127);
    const Wide x = Wide(a.mantissa) << (a.power - power), y = Wide(b.mantissa) << (b.power - power);
    if (a.negative == b.negative) return rounded(a.negative, x + y, 1, power, precision);
    return x >= y ? rounded(a.negative, x - y, 1, power, precision) :
                    rounded(b.negative, y - x, 1, power, precision);
}
Binary times(Binary a, Binary b, unsigned precision = 24) {
    return rounded(a.negative != b.negative, Wide(a.mantissa) * b.mantissa, 1,
                   a.power + b.power, precision);
}
Binary divided(Binary a, Binary b, unsigned precision = 24) {
    assert(b.mantissa);
    return rounded(a.negative != b.negative, a.mantissa, b.mantissa,
                   a.power - b.power, precision);
}
std::int64_t truncated(Binary a) {
    assert(a.power < 40);
    const auto magnitude = a.power <= -64 ? 0 : a.power < 0 ? a.mantissa >> -a.power :
                                                                     a.mantissa << a.power;
    return a.negative ? -std::int64_t(magnitude) : std::int64_t(magnitude);
}
std::int64_t away(Binary a) {
    if (a.power >= 0) return truncated(a);
    a.negative = false;
    // The quotient is at most24576; forming its fractional half is exact.
    auto result = truncated(plus(convert(a, 53), {false, 1, -1}, 53));
    return result;
}
Binary bounded(float input, bool signed_range) {
    auto raw = std::bit_cast<std::uint32_t>(input);
    assert((raw & 0x7f800000u) != 0x7f800000u);
    if (!signed_range && (raw >> 31)) return {};
    return raw_float((raw & 0x80000000u) | std::min(raw & 0x7fffffffu, 0x42c80000u));
}
std::uint32_t percent(Binary input) {
    // Input is already bounded; exact integer rational arithmetic rounds each
    // binary32 operation, including small products and division halfway cases.
    return std::uint32_t(truncated(divided(times(input, integer(255)), integer(100))));
}
std::uint32_t percentage(float value) { return percent(bounded(value, false)); }
std::uint32_t extent(std::uint32_t value) {
    return std::max(percent(convert(integer(std::min(value, 100u)))), 8u);
}
std::uint32_t adjustment(float value, std::uint32_t hue) {
    const auto normalized = plus(divided(plus(bounded(value, true), integer(100)), integer(100)), integer(-1));
    const auto coefficient = divided(times(normalized, integer(262144)), integer(hue));
    return std::uint32_t(std::clamp(truncated(plus(coefficient, {false, 1, -1})),
                                   std::int64_t(-32768), std::int64_t(32767))) & 0xffffu;
}
std::uint32_t reciprocal(std::uint32_t value) {
    return std::uint32_t(truncated(plus(divided(integer(65536), integer(value), 53),
                                          {false, 1, -1}, 53)));
}
o82::MemoryColorData reference(const o82::MemoryColorInput &in) {
    const auto h = std::max(std::int64_t(8), std::clamp(std::int64_t(in.hue_extent),
                                                     std::int64_t(0), std::int64_t(360)) * 64 / 15);
    const auto s = extent(in.saturation_extent), v = extent(in.value_extent);
    const auto delta = std::clamp(std::int64_t(in.hue_adjustment), std::int64_t(-180),
                                  std::int64_t(180)) * 64 / 15;
    const auto ratio = times(convert(divided(integer(delta), integer(h), 53)), integer(256));
    const auto hue_ratio = ratio.negative ? -away(ratio) : away(ratio);
    const auto region = [](std::int64_t value) {
        if (value < 0) value += 360;
        return std::uint32_t(std::clamp(value, std::int64_t(0), std::int64_t(360)) * 64 / 15);
    };
    return {std::uint32_t(h) | ((std::uint32_t(hue_ratio) & 65535) << 16),
            adjustment(in.saturation_adjustment, h) | (adjustment(in.value_adjustment, h) << 16),
            reciprocal(s) | (reciprocal(v) << 16),
            std::uint32_t(truncated(divided(integer(2147483648), convert(integer(h * s * v))))),
            std::uint8_t(in.saturation_hold_control < 3 ? 3 - in.saturation_hold_control : 0),
            std::uint8_t(in.value_hold_control < 3 ? 3 - in.value_hold_control : 0),
            region(in.hue_minimum) | (region(in.hue_maximum) << 16),
            percentage(in.saturation_minimum) | (percentage(in.saturation_maximum) << 8) | (s << 16),
            percentage(in.value_minimum) | (percentage(in.value_maximum) << 8) | (v << 16)};
}
unsigned checks = 0, reciprocal_differences = 0, symmetric_differences = 0, reversed_ranges = 0;
void report(const o82::MemoryColorData &actual, const o82::MemoryColorData &expected) {
    const auto print = [](const char *name, const o82::MemoryColorData &v) {
        std::fprintf(stderr, "%s: %08x %08x %08x %08x %u %u %08x %08x %08x\n",
            name, v.adjust_p0, v.adjust_p1, v.adjust_p2, v.blend_gain,
            unsigned(v.saturation_hold), unsigned(v.value_hold),
            v.hue_region, v.saturation_region, v.value_region);
    };
    print("actual synthetic words", actual); print("expected synthetic words", expected);
}
void verify(o82::MemoryColorInput in) {
    const auto original = o82::MemoryColorData{1,2,3,4,1,2,5,6,7};
    auto result = original;
    assert(o82::compile_memory_color(in, result) == o82::MemoryColorError::none);
    const auto expected = reference(in);
    if (!(result == expected)) { std::fprintf(stderr, "Integer-oracle case %u\n", checks); report(result, expected); }
    assert(result == expected);
    const auto h = result.adjust_p0 & 0x7ffu, s = result.saturation_region >> 16;
    reciprocal_differences += (result.adjust_p2 & 65535) != 65536 / s;
    const auto wrong = std::uint32_t(std::clamp(std::int64_t(std::round(
        std::clamp(double(in.saturation_adjustment), -100.0, 100.0) / 100.0 * 262144.0 / h)),
        std::int64_t(-32768), std::int64_t(32767))) & 65535;
    symmetric_differences += wrong != (result.adjust_p1 & 65535);
    reversed_ranges += (result.hue_region & 65535) != (result.hue_region >> 16) ||
                       (result.saturation_region & 255) != ((result.saturation_region >> 8) & 255) ||
                       (result.value_region & 255) != ((result.value_region >> 8) & 255);
    assert(result.saturation_hold <= 3 && result.value_hold <= 3);
    assert(!(result.adjust_p0 & 0xf800u) && !(result.hue_region & 0xf800f800u));
    ++checks;
}
void golden(o82::MemoryColorInput in, o82::MemoryColorData expected) {
    o82::MemoryColorData out;
    assert(o82::compile_memory_color(in,out) == o82::MemoryColorError::none);
    if (!(out == expected)) report(out, expected);
    assert(out == expected);
    verify(in);
}
} // namespace

int main() {
    assert(std::fegetround() == FE_TONEAREST);
    golden({}, {8,0,0x20002000,0x400000,3,3,0,0x80000,0x80000});
    o82::MemoryColorInput in;
    in.hue_adjustment = 180; in.hue_extent = 360;
    in.saturation_adjustment = 100; in.value_adjustment = -100;
    in.saturation_extent = in.value_extent = 100;
    in.saturation_hold_control = in.value_hold_control = 3;
    in.hue_minimum = -180; in.hue_maximum = 180;
    in.saturation_maximum = in.value_maximum = 100;
    golden(in, {0x800600,0xff5600ab,0x1010101,21,0,0,0x3000300,0xffff00,0xffff00});
    in = {}; in.saturation_adjustment = -100; in.value_adjustment = 100;
    golden(in, {8,0x7fff8001,0x20002000,0x400000,3,3,0,0x80000,0x80000});
    in.hue_adjustment = -180; in.hue_minimum = -360; in.hue_maximum = INT_MAX;
    golden(in, {0xa0000008,0x7fff8001,0x20002000,0x400000,3,3,0x6000000,0x80000,0x80000});
    in={};in.hue_minimum=0;in.hue_maximum=90;
    in.saturation_minimum=12.5f;in.saturation_maximum=87.25f;
    in.value_minimum=3.125f;in.value_maximum=98.5f;
    golden(in,{8,0,0x20002000,0x400000,3,3,0x1800000,0x8de1f,0x8fb07});
    for (int hue = -180; hue <= 180; ++hue)
        for (int width = 0; width <= 360; width += 5) {
            in = {}; in.hue_adjustment=hue; in.hue_extent=width;
            in.saturation_adjustment = -13.75f; in.value_adjustment = 43.125f;
            in.saturation_extent=97; in.value_extent=61;
            verify(in);
        }
    for (int width = 0; width <= 360; ++width)
        for (unsigned s = 0; s <= 100; ++s) {
            in = {}; in.hue_extent=width; in.saturation_extent=s; in.value_extent=100-s;
            in.saturation_adjustment=-100; in.value_adjustment=100;
            in.saturation_hold_control=s; in.value_hold_control=100-s;
            verify(in);
        }
    std::uint32_t random = 0x82c017;
    const auto next = [&] { random=random*1664525u+1013904223u; return random; };
    for (unsigned n=0; n<20000; ++n) {
        const auto raw=next(); if ((raw&0x7f800000u)==0x7f800000u) continue;
        const auto value=std::bit_cast<float>(raw);
        in={}; in.hue_adjustment=std::bit_cast<std::int32_t>(next());
        in.hue_extent=int(next()%400)-20;
        in.saturation_adjustment=value; in.value_adjustment=-value;
        in.saturation_extent=next(); in.value_extent=next()%110;
        in.hue_minimum=std::bit_cast<std::int32_t>(next()); in.hue_maximum=-200;
        in.saturation_minimum=value; in.saturation_maximum=-value;
        in.value_minimum=33.125f; in.value_maximum=value;
        verify(in);
    }
    const std::array<float o82::MemoryColorInput::*,6> fields{
        &o82::MemoryColorInput::saturation_adjustment, &o82::MemoryColorInput::value_adjustment,
        &o82::MemoryColorInput::saturation_minimum, &o82::MemoryColorInput::saturation_maximum,
        &o82::MemoryColorInput::value_minimum, &o82::MemoryColorInput::value_maximum};
    const auto original=o82::MemoryColorData{1,2,3,4,1,2,5,6,7};
    for (const auto field:fields)
        for (float value:{INFINITY,-INFINITY,std::numeric_limits<float>::quiet_NaN()}) {
            in={}; in.*field=value; auto out=original;
            assert(o82::compile_memory_color(in,out)==o82::MemoryColorError::nonfinite && out==original);
        }
    for (int mode:{FE_DOWNWARD,FE_UPWARD,FE_TOWARDZERO}) {
        assert(std::fesetround(mode)==0); auto out=original;
        assert(o82::compile_memory_color({},out)==o82::MemoryColorError::rounding_mode && out==original);
    }
    assert(std::fesetround(FE_TONEAREST)==0);
    assert(reciprocal_differences && symmetric_differences && reversed_ranges);
    std::printf("Memory-color conversion: %u integer-oracle cases, hand words, clamps, hue wrap, holds and unchanged refusal passed; synthetic inputs only\n",checks);
    std::printf("Required wrong alternatives differ: floor reciprocal=%u, symmetric/wide adjustment=%u\n",reciprocal_differences,symmetric_differences);
    std::printf("Distinct endpoint cases detect reversed named ranges: %u\n",reversed_ranges);
}
