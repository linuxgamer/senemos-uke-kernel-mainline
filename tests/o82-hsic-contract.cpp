// SPDX-License-Identifier: MIT
// Synthetic protocol inputs only. No OEM code, coefficients or hardware I/O.
#include "o82-hsic.h"

#include <array>
#include <bit>
#include <cassert>
#include <climits>
#include <cstdio>

namespace {
unsigned checks = 0, wide_differences = 0, rounded_differences = 0;

// Independent binary-rational reference. Decode IEEE754 bits and round the
// integer product/quotient to 24 significant bits, ties to even. No floating-
// point multiply/divide implements this oracle. Subnormal final values always
// truncate to zero, so their final float encoding is immaterial here.
std::uint64_t round_shift(std::uint64_t value, unsigned shift) {
    if (!shift) return value;
    const auto quotient = value >> shift;
    const auto remainder = value & ((std::uint64_t(1) << shift) - 1);
    const auto half = std::uint64_t(1) << (shift - 1);
    return quotient + (remainder > half || (remainder == half && (quotient & 1)));
}
std::uint32_t reference(float input, float bound, unsigned scale, unsigned divisor,
                        bool positive_only = false) {
    const auto raw = std::bit_cast<std::uint32_t>(input);
    if (positive_only && (raw >> 31)) return 0;
    auto magnitude = raw & 0x7fffffffu;
    const auto bound_bits = std::bit_cast<std::uint32_t>(bound);
    if (magnitude > bound_bits) magnitude = bound_bits;
    const unsigned exponent = magnitude >> 23;
    std::uint64_t mantissa = magnitude & 0x7fffff;
    int power = -149;
    if (exponent) { mantissa |= 1u << 23; power = int(exponent) - 150; }
    if (!mantissa) return 0;
    mantissa *= scale;
    const unsigned shift = std::bit_width(mantissa) > 24 ? std::bit_width(mantissa) - 24 : 0;
    mantissa = round_shift(mantissa, shift);
    power += shift;
    if (divisor != 1) {
        assert(divisor == 255);
        int order = int(std::bit_width(mantissa)) - 1 - 8;
        const int probe = order + 1;
        if (probe >= 0 ? mantissa >= (std::uint64_t(255) << probe) :
                         (mantissa << -probe) >= 255) order++;
        const auto numerator = mantissa << (23 - order);
        auto quotient = numerator / 255;
        const auto remainder = numerator % 255;
        quotient += remainder * 2 > 255 || (remainder * 2 == 255 && (quotient & 1));
        mantissa = quotient;
        power += order - 23;
    }
    const auto truncated = power < -63 ? 0 : power < 0 ? mantissa >> -power : mantissa << power;
    const auto signed_value = raw >> 31 ? -std::int32_t(truncated) : std::int32_t(truncated);
    return static_cast<std::uint32_t>(signed_value) & 0xffu;
}

void verify(o82::HsicInput input) {
    o82::HsicData output{0x123,0x4567,0x89,0xab,true};
    assert(o82::compile_hsic(input, output) == o82::HsicError::none);
    const auto hue = std::int64_t(input.hue < -180 ? -180 : input.hue > 180 ? 180 : input.hue);
    const auto saturation = reference(input.saturation,1.0f,65,1) |
                            (reference(input.saturation_threshold,1.0f,255,1,true) << 8);
    assert(output == (o82::HsicData{
        static_cast<std::uint32_t>(hue * 768 / 180) & 0xfffu,
        saturation, reference(input.value,255.0f,65,255), reference(input.contrast,1.0f,65,1),
        input.hue != 0 || input.saturation != 0 || input.value != 0 ||
        input.contrast != 0 || input.saturation_threshold != 0}));
    const double bounded = std::clamp(double(input.value),-255.0,255.0);
    const auto wide = static_cast<std::uint32_t>(static_cast<std::int32_t>(bounded * 65.0 / 255.0)) & 0xffu;
    wide_differences += wide != output.value;
    const auto rounded = static_cast<std::uint32_t>(std::lround(bounded * 65.0 / 255.0)) & 0xffu;
    rounded_differences += rounded != output.value;
    checks++;
}
void golden(o82::HsicInput input, o82::HsicData expected) {
    o82::HsicData output;
    assert(o82::compile_hsic(input,output) == o82::HsicError::none && output == expected);
    verify(input);
}
}

int main() {
    assert(std::fegetround() == FE_TONEAREST);
    golden({},{});
    golden({180,1,255,1,1},{0x300,0xff41,0x41,0x41,true});
    golden({-180,-1,-255,-1,0},{0xd00,0xbf,0xbf,0xbf,true});
    golden({42,.5f,127.5f,-.5f,.5f},{0xb3,0x7f20,0x20,0xe0,true});
    golden({INT_MAX,999,999,999,999},{0x300,0xff41,0x41,0x41,true});
    golden({INT_MIN,-999,-999,-999,-999},{0xd00,0xbf,0xbf,0xbf,true});
    golden({0,-0.0f,-0.0f,-0.0f,-0.0f},{});
    golden({0,std::numeric_limits<float>::denorm_min(),0,0,0},{0,0,0,0,true});
    for (int h=-1000;h<=1000;h++) verify({h});
    for (int integer=-65;integer<=65;integer++) {
        for (unsigned axis=0;axis<4;axis++) {
            const float bound = axis == 1 ? 255.0f : 1.0f;
            float center = float(double(integer) * bound / (axis == 3 ? 255.0 : 65.0));
            for (int direction : {-1,1}) {
                float value = center;
                for (unsigned ulp=0;ulp<9;ulp++) {
                    o82::HsicInput input;
                    if (axis==0) input.saturation=value;
                    if (axis==1) input.value=value;
                    if (axis==2) input.contrast=value;
                    if (axis==3) input.saturation_threshold=value;
                    verify(input);
                    value=std::nextafter(value,direction<0 ? -INFINITY : INFINITY);
                }
            }
        }
    }
    std::uint32_t random=0x83517;
    for (unsigned n=0;n<30000;n++) {
        random=random*1664525u+1013904223u;
        if ((random & 0x7f800000u)==0x7f800000u) continue;
        const float value=std::bit_cast<float>(random);
        verify({std::bit_cast<std::int32_t>(random),value,value,value,value});
    }
    const auto original=o82::HsicData{0x123,0x4567,0x89,0xab,true};
    for (float bad : {INFINITY,-INFINITY,std::numeric_limits<float>::quiet_NaN()}) {
        for (unsigned axis=0;axis<4;axis++) {
            o82::HsicInput input;
            if (axis==0) input.saturation=bad;
            if (axis==1) input.value=bad;
            if (axis==2) input.contrast=bad;
            if (axis==3) input.saturation_threshold=bad;
            auto output=original;
            assert(o82::compile_hsic(input,output)==o82::HsicError::nonfinite && output==original);
            checks++;
        }
    }
    for (int mode : {FE_DOWNWARD,FE_UPWARD,FE_TOWARDZERO}) {
        assert(!std::fesetround(mode));
        auto output=original;
        assert(o82::compile_hsic({},output)==o82::HsicError::rounding_mode && output==original);
        checks++;
    }
    assert(!std::fesetround(FE_TONEAREST));
    assert(wide_differences && rounded_differences);
    std::printf("HSIC converter: %u synthetic checks passed; independent integer oracle, signed packing, typed activation and transactional refusal; wide/rounded alternatives rejected (%u/%u); no hardware or private data\n",checks,wide_differences,rounded_differences);
}
