// SPDX-License-Identifier: MIT
// Synthetic curves; independent integer IEEE754 and analytic power-law oracles.
#include "o82-hdr-tonemap.h"
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>

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
std::uint32_t encode(Binary value) {
    if (!value.mantissa) return 0;
    const int top = int(std::bit_width(value.mantissa)) - 1;
    const int exponent = top + value.power;
    assert(exponent <= 127);
    const auto sign = std::uint32_t(value.negative) << 31;
    if (exponent < -126) {
        const int shift = value.power + 149;
        assert(shift >= 0 && shift < 24);
        return sign | std::uint32_t(value.mantissa << shift);
    }
    const auto mantissa = value.mantissa << (23 - top);
    return sign | (std::uint32_t(exponent + 127) << 23) |
           (std::uint32_t(mantissa) & 0x7fffffu);
}
Binary negated(Binary value) { if (value.mantissa) value.negative = !value.negative; return value; }
Binary binary(float value) { return raw_float(std::bit_cast<std::uint32_t>(value)); }
unsigned exact_cases = 0, analytic_cases = 0, refusal_cases = 0, wide_differences = 0;
std::uint32_t reference(const o82::HdrLogCurve &curve, float value, o82::HdrCurveDirection direction) {
    const bool inverse = direction == o82::HdrCurveDirection::to_source;
    const auto &x = inverse ? curve.panel : curve.source;
    const auto &y = inverse ? curve.source : curve.panel;
    if (value <= x[0]) return std::bit_cast<std::uint32_t>(y[0]);
    // Independent linear interval scan, with an integer-rational arithmetic
    // model. No production binary search or floating-point interpolation.
    for (std::size_t i = 1; i < curve.count; ++i) {
        if (value > x[i]) continue;
        if (value == x[i]) return std::bit_cast<std::uint32_t>(y[i]);
        const auto fraction = divided(plus(binary(value), negated(binary(x[i - 1]))),
                                      plus(binary(x[i]), negated(binary(x[i - 1]))));
        const auto result = plus(times(binary(y[i]), fraction),
            times(binary(y[i - 1]), plus(integer(1), negated(fraction))));
        const double wide = double(y[i - 1]) + (double(y[i]) - y[i - 1]) *
            ((double(value) - x[i - 1]) / (double(x[i]) - x[i - 1]));
        const auto expected = encode(result);
        wide_differences += std::bit_cast<std::uint32_t>(float(wide)) != expected;
        return expected;
    }
    std::size_t first_max = 0;
    while (x[first_max] < x[curve.count - 1]) first_max++;
    return std::bit_cast<std::uint32_t>(y[first_max]);
}
void verify(const o82::HdrLogCurve &curve, float value, o82::HdrCurveDirection direction) {
    float actual = 1234;
    assert(o82::map_hdr_log_luminance(curve, value, direction, actual) == o82::HdrCurveError::none);
    const auto expected = reference(curve, value, direction);
    if (!(actual == 0 && (expected & 0x7fffffffu) == 0) &&
        std::bit_cast<std::uint32_t>(actual) != expected) {
        std::fprintf(stderr, "synthetic curve mismatch: actual=%08x expected=%08x\n",
                     std::bit_cast<std::uint32_t>(actual), expected);
        assert(false);
    }
    exact_cases++;
}
void plateaus() {
    o82::HdrLogCurve curve;
    const std::array<float, 5> x{-2,0,1,2,3}, y{-2,0,0,0,2};
    assert(o82::compile_hdr_log_curve(x,y,curve) == o82::HdrCurveError::none);
    float out;
    assert(o82::map_hdr_log_luminance(curve,0,o82::HdrCurveDirection::to_source,out) ==
           o82::HdrCurveError::none && out == 0);
    for (int sample = -64; sample <= 64; ++sample)
        for (const auto direction : {o82::HdrCurveDirection::to_panel,o82::HdrCurveDirection::to_source})
            verify(curve,float(sample)/16,direction);
    const std::array<float,5> terminal{-2,0,1,1,1};
    assert(o82::compile_hdr_log_curve(x,terminal,curve) == o82::HdrCurveError::none);
    for (float value : {1.0f,2.0f,999.0f}) {
        assert(o82::map_hdr_log_luminance(curve,value,o82::HdrCurveDirection::to_source,out) ==
               o82::HdrCurveError::none && out == 1);
        verify(curve,value,o82::HdrCurveDirection::to_source);
    }
    const std::array<float,5> flat{1,1,1,1,1};
    assert(o82::compile_hdr_log_curve(x,flat,curve) == o82::HdrCurveError::none);
    for (float value : {-100.0f,1.0f,100.0f}) verify(curve,value,o82::HdrCurveDirection::to_source);
}
int plateau_control() {
    o82::HdrLogCurve curve;
    const std::array<float,5> x{-2,0,1,2,3}, y{-2,0,0,0,2};
    if (o82::compile_hdr_log_curve(x,y,curve) != o82::HdrCurveError::none) return 20;
    float output = 999;
    if (o82::map_hdr_log_luminance(curve,0,o82::HdrCurveDirection::to_source,output) !=
        o82::HdrCurveError::none) return 21;
    if (output != 0) { std::puts("Required inverse plateau ownership assertion rejected mutant"); return 42; }
    return 0;
}
void refusal_tests() {
    using E = o82::HdrCurveError;
    const std::array<float,2> x{-2,2}, y{-1,1};
    o82::HdrLogCurve curve;
    assert(o82::compile_hdr_log_curve(x,y,curve) == E::none);
    const auto original = curve;
    const auto refuse_compile = [&](std::span<const float> a,std::span<const float> b,E expected) {
        assert(o82::compile_hdr_log_curve(a,b,curve) == expected && curve == original);
        refusal_cases++;
    };
    refuse_compile({},y,E::size); refuse_compile(x,{},E::size);
    refuse_compile(std::span(x).first(1),std::span(y).first(1),E::size);
    const std::array<float,18> too_many{}; refuse_compile(too_many,too_many,E::size);
    for (const float bad : {std::numeric_limits<float>::infinity(),
                           -std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
        const std::array<float,2> values{-2,bad};
        refuse_compile(values,y,E::nonfinite); refuse_compile(x,values,E::nonfinite);
        float output = 1234;
        assert(o82::map_hdr_log_luminance(curve,bad,o82::HdrCurveDirection::to_panel,output) ==
               E::nonfinite && output == 1234); refusal_cases++;
    }
    const std::array<float,2> duplicate{1,1}, descending{2,-2};
    refuse_compile(duplicate,y,E::order); refuse_compile(descending,y,E::order);
    refuse_compile(x,descending,E::order);
    float output = 1234;
    assert(o82::map_hdr_log_luminance(curve,0,static_cast<o82::HdrCurveDirection>(99),output) ==
           E::direction && output == 1234); refusal_cases++;
    for (const o82::HdrLuminanceRange range : {o82::HdrLuminanceRange{0,0},{1,1},{2,1},
                                             {-1,100},{0,10001},{0,1e-8f}}) {
        assert(o82::map_hdr_normalized_luminance(curve,range,0.5f,
               o82::HdrCurveDirection::to_panel,output) == E::range && output == 1234); refusal_cases++;
    }
    auto forged = curve; forged.count = 1000;
    assert(o82::map_hdr_log_luminance(forged,0,o82::HdrCurveDirection::to_panel,output) ==
           E::size && output == 1234); refusal_cases++;
    assert(!std::fesetround(FE_DOWNWARD));
    assert(o82::map_hdr_log_luminance(curve,0,o82::HdrCurveDirection::to_panel,output) ==
           E::rounding_mode && output == 1234); refusal_cases++;
    assert(!std::fesetround(FE_TONEAREST));
    const std::array<float,2> extremes{-std::numeric_limits<float>::max(),std::numeric_limits<float>::max()};
    assert(o82::compile_hdr_log_curve(extremes,y,curve) == E::none);
    assert(o82::map_hdr_log_luminance(curve,0,o82::HdrCurveDirection::to_panel,output) ==
           E::range && output == 1234); refusal_cases++;
}
void generated_curves() {
    std::uint32_t state = 0x73a5b19u;
    const auto random = [&] { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state; };
    for (unsigned trial = 0; trial < 2048; ++trial) {
        std::array<float,17> x{},y{}; const auto count = std::size_t(2 + random()%16);
        x[0] = -4; y[0] = -3;
        for (std::size_t i = 1; i < count; ++i) {
            x[i] = x[i-1] + float(1 + random()%100)/128;
            y[i] = y[i-1] + float(random()%80)/128;
        }
        o82::HdrLogCurve curve;
        assert(o82::compile_hdr_log_curve(std::span(x).first(count),std::span(y).first(count),curve) ==
               o82::HdrCurveError::none);
        for (std::size_t i = 0; i < count; ++i) {
            verify(curve,x[i],o82::HdrCurveDirection::to_panel);
            verify(curve,y[i],o82::HdrCurveDirection::to_source);
            verify(curve,std::nextafter(x[i],-std::numeric_limits<float>::infinity()),o82::HdrCurveDirection::to_panel);
            verify(curve,std::nextafter(y[i],std::numeric_limits<float>::infinity()),o82::HdrCurveDirection::to_source);
        }
        for (unsigned i = 0; i < 64; ++i) {
            const float q = float(int(random()%8192)-4096)/512;
            verify(curve,q,o82::HdrCurveDirection::to_panel);
            verify(curve,q,o82::HdrCurveDirection::to_source);
        }
    }
    assert(wide_differences > 100);
}
void analytic_luminance() {
    for (const float slope : {0.5f,1.0f,1.5f}) {
        std::array<float,17> x{},y{};
        for (unsigned i=0;i<17;++i) { x[i]=-6+float(i)*0.625f; y[i]=slope*x[i]+0.25f; }
        o82::HdrLogCurve curve;
        assert(o82::compile_hdr_log_curve(x,y,curve) == o82::HdrCurveError::none);
        const o82::HdrLuminanceRange range{0,1000};
        const long double black = std::bit_cast<float>(0x3356bf96u);
        const long double span = 0.1L-black;
        for (unsigned i=1;i<=4096;++i) {
            const float value = float(i)/4096;
            const long double mapped = std::pow(10.0L,0.25L)*std::pow(10000.0L*value,slope)/10000;
            const long double expected = std::max(mapped-black,0.0L)/span;
            float output = 999;
            assert(o82::map_hdr_normalized_luminance(curve,range,value,o82::HdrCurveDirection::to_panel,output) ==
                   o82::HdrCurveError::none);
            assert(std::abs((long double)output-expected) <= 4e-6L*std::max(1.0L,std::abs(expected)));
            analytic_cases++;
            const long double absolute = span*value+black;
            const long double inverse = std::clamp(
                std::pow((10000*absolute)/std::pow(10.0L,0.25L),1.0L/slope)/10000,1e-10L,1.0L);
            assert(o82::map_hdr_normalized_luminance(curve,range,value,o82::HdrCurveDirection::to_source,output) ==
                   o82::HdrCurveError::none);
            assert(std::abs((long double)output-inverse) <= 4e-6L*std::max(1.0L,std::abs(inverse)));
            analytic_cases++;
        }
        float output = 999;
        for (const float input : {-1.0f,0.0f}) {
            assert(o82::map_hdr_normalized_luminance(curve,range,input,o82::HdrCurveDirection::to_panel,output) ==
                   o82::HdrCurveError::none && output == 0); analytic_cases++;
        }
    }
}
} // namespace
int main(int argc,char **argv) {
    if (argc == 2 && !std::strcmp(argv[1],"--inverse-plateau-control")) return plateau_control();
    assert(argc == 1 && std::fegetround() == FE_TONEAREST);
    plateaus(); refusal_tests(); generated_curves(); analytic_luminance();
    std::printf("HDR typed log curve: %u exact integer-oracle, %u analytic luminance, %u refusal cases; %u wider-arithmetic differences\n",
                exact_cases,analytic_cases,refusal_cases,wide_differences);
    return 0;
}
