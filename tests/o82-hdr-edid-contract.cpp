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

int main() {
    std::array<unsigned char, O82_HDR_EDID_SIZE + 2> storage{};
    storage.front() = storage.back() = 0xa5;
    auto *bytes = storage.data() + 1;
    o82_hdr_make_edid(bytes);
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
    assert(edid && metadata && color && metadata->pq && color->bt2020_rgb);
    assert(metadata->desired_content_max_luminance > 410 && metadata->desired_content_max_luminance <= 420);
    assert(metadata->desired_content_min_luminance > 0.30 && metadata->desired_content_min_luminance < 0.35);
    const auto *primaries = di_edid_get_chromaticity_coords(edid);
    assert(primaries && std::abs(primaries->red_x - 0.68) < 0.001 && std::abs(primaries->green_y - 0.69) < 0.001);
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
    std::puts("Original KWin EDID inputs: PQ, BT.2020 RGB, P3, nominal OEM luminance and native high-clock DisplayID passed");
}
