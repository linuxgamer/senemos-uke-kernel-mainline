// SPDX-License-Identifier: MIT
// Synthetic protocol coordinates only; no OEM calibration or hardware access.
#ifndef O82_COLOR_IMPLEMENTATION
#define O82_COLOR_IMPLEMENTATION "o82-color-profile.cpp"
#endif
#include O82_COLOR_IMPLEMENTATION

namespace {
constexpr unsigned knots[]{0, 256, 512, 768, 1024, 1280, 1536, 1792, 2048,
                           2304, 2560, 2816, 3072, 3328, 3584, 3840, 4095};
unsigned failures, checks;
void check_near(double actual, double expected, double tolerance = 1e-12) {
    ++checks;
    failures += !std::isfinite(actual) || std::abs(actual - expected) > tolerance;
}
double coordinate(unsigned index) { return knots[index] / 4095.0; }
Vec asymmetric(double r, double g, double b) {
    return {0.1 + 0.7 * r * r + 0.1 * g,
            0.1 + 0.6 * g + 0.2 * b,
            0.05 + 0.4 * b * b + 0.1 * r};
}
void check_vector(Vec actual, Vec expected) {
    for (unsigned channel = 0; channel < 3; ++channel)
        check_near(actual[channel], expected[channel]);
}
void check_interpolation() {
    Profile profile;
    for (unsigned b = 0; b < 17; ++b)
        for (unsigned g = 0; g < 17; ++g)
            for (unsigned r = 0; r < 17; ++r)
                profile.gamut.push_back(asymmetric(coordinate(r), coordinate(g), coordinate(b)));
    for (unsigned b = 0; b < 17; ++b)
        for (unsigned g = 0; g < 17; ++g)
            for (unsigned r = 0; r < 17; ++r)
                check_vector(profile.gamut_map({coordinate(r), coordinate(g), coordinate(b)}),
                             asymmetric(coordinate(r), coordinate(g), coordinate(b)));
    for (unsigned r = 0; r < 16; ++r) {
        const unsigned g = (r * 7) % 16, b = (r * 11) % 16;
        const double r0 = coordinate(r), r1 = coordinate(r + 1);
        const double gmid = (coordinate(g) + coordinate(g + 1)) / 2;
        const double b0 = coordinate(b), b1 = coordinate(b + 1);
        const double rmid = (r0 + r1) / 2, bmid = (b0 + b1) / 2;
        check_vector(profile.gamut_map({rmid, gmid, bmid}),
                     {0.1 + 0.7 * (r0 * r0 + r1 * r1) / 2 + 0.1 * gmid,
                      0.1 + 0.6 * gmid + 0.2 * bmid,
                      0.05 + 0.4 * (b0 * b0 + b1 * b1) / 2 + 0.1 * rmid});
    }
    check_vector(profile.gamut_map({-1, -1, -1}), asymmetric(0, 0, 0));
    check_vector(profile.gamut_map({2, 2, 2}), asymmetric(1, 1, 1));
}
void check_native_sampling() {
    Profile identity;
    for (unsigned c = 0; c < 3; ++c) {
        for (unsigned i = 0; i < 257; ++i) identity.igc[c].push_back(i / 256.0);
        for (unsigned i = 0; i < 1024; ++i) identity.gc[c].push_back(i / 1023.0);
    }
    for (unsigned b = 0; b < 17; ++b)
        for (unsigned g = 0; g < 17; ++g)
            for (unsigned r = 0; r < 17; ++r)
                identity.gamut.push_back({coordinate(r), coordinate(g), coordinate(b)});
    const auto data = native_tables(identity, O82_COLOR_P3);
    const auto *cube = data.data() + 2 * O82_COLOR_FW_CURVE_BYTES;
    for (unsigned b = 0; b < 17; ++b)
        for (unsigned g = 0; g < 17; ++g)
            for (unsigned r = 0; r < 17; ++r) {
                const unsigned axes[]{r, g, b};
                const unsigned node = (b * 17 + g) * 17 + r;
                for (unsigned c = 0; c < 3; ++c) {
                    const double value = coordinate(axes[c]);
                    const double encoded = value <= 0.0031308 ? value * 12.92 :
                        1.055 * std::pow(value, 1 / 2.4) - 0.055;
                    const unsigned expected = std::lround(encoded * 4095);
                    check_near(o82_hdr_u16(cube + 6 * node + 2 * c), expected, 1);
                }
            }
}
}
// Redirect the CRT entry at link time, preserving C++ main's implicit return.
extern "C" int __wrap_main(int, char **) {
    check_interpolation();
    check_native_sampling();
    if (failures) {
        std::printf("OEM gamut grid regression rejected: %u/%u checks failed\n", failures, checks);
        return 1;
    }
    std::printf("OEM gamut grid: %u asymmetric knot, midpoint, endpoint and native RGB sampling checks passed\n", checks);
    return 0;
}
