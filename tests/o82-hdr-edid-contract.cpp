// SPDX-License-Identifier: MIT
// Use the same libdisplay-info metadata consumed by original KWin 6.8.2.
extern "C" {
#include <libdisplay-info/info.h>
#include <libdisplay-info/edid.h>
#include <libdisplay-info/displayid.h>
}
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include "uke-o82-hdr-format.h"

void check_edid(unsigned primaries, unsigned native_hdr) {
    std::array<unsigned char, O82_HDR_EDID_SIZE + 2> storage{};
    storage.front() = storage.back() = 0xa5;
    auto *bytes = storage.data() + 1;
    assert(o82_color_make_edid(bytes, primaries, native_hdr));
    assert(storage.front() == 0xa5 && storage.back() == 0xa5);
    for (unsigned block = 0; block < 3; block++) {
        unsigned sum = 0;
        for (unsigned i = 0; i < 128; i++) sum += bytes[block * 128 + i];
        assert((sum & 255) == 0);
    }
    auto *info = di_info_parse_edid(bytes, O82_HDR_EDID_SIZE);
    assert(info);
    const auto *edid = di_info_get_edid(info);
    const auto *metadata = di_info_get_hdr_static_metadata(info);
    const auto *color = di_info_get_supported_signal_colorimetry(info);
    assert(edid && bool(metadata && metadata->pq) == bool(native_hdr));
    assert(bool(color && color->bt2020_rgb) == bool(native_hdr));
    if (native_hdr) {
        assert(metadata->desired_content_max_luminance > 410 && metadata->desired_content_max_luminance <= 420);
        assert(metadata->desired_content_min_luminance > 0.30 && metadata->desired_content_min_luminance < 0.35);
    }
    const auto *xy = di_edid_get_chromaticity_coords(edid);
    const double red_x = primaries == O82_COLOR_P3 ? 0.68 : 0.64;
    const double green_y = primaries == O82_COLOR_P3 ? 0.69 : 0.60;
    assert(xy && std::abs(xy->red_x - red_x) < 0.001 && std::abs(xy->green_y - green_y) < 0.001);
    bool native = false;
    for (auto extension = di_edid_get_extensions(edid); *extension; extension++) {
        const auto *displayid = di_edid_ext_get_displayid(*extension);
        if (!displayid) continue;
        for (auto block = di_displayid_get_data_blocks(displayid); *block; block++) {
            const auto *timings = di_displayid_data_block_get_type_i_timings(*block);
            if (timings && timings[0]) native = true;
        }
    }
    assert(native);
    const char *failure = di_info_get_failure_msg(info);
    if (failure) std::fprintf(stderr, "%s\n", failure);
    assert(!failure);
    di_info_destroy(info);
}
int main() {
    std::array<unsigned char, O82_HDR_EDID_SIZE> untouched;
    untouched.fill(0xa5);
    assert(!o82_color_make_edid(nullptr, O82_COLOR_P3, 1));
    assert(!o82_color_make_edid(untouched.data(), 2, 1));
    assert(!o82_color_make_edid(untouched.data(), O82_COLOR_P3, 2));
    for (auto byte : untouched) assert(byte == 0xa5);
    for (unsigned primaries : {O82_COLOR_SRGB, O82_COLOR_P3})
        for (unsigned hdr : {0, 1}) check_edid(primaries, hdr);
    std::puts("Original KWin EDID inputs: sRGB/P3 modes, gated PQ/BT.2020, nominal luminance and native DisplayID passed without warnings");
}
