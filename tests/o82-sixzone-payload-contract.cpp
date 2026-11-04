// SPDX-License-Identifier: MIT
// Actual parser/serializer and shared C validation, with synthetic inputs only.
#include "o82-color-profile.cpp"

namespace {
unsigned payload_checks;
void payload_check(bool value) {
    ++payload_checks;
    if (!value) throw std::runtime_error("SixZone payload contract failed");
}
Json picture_fixture() {
    auto picture = parse(R"({"SixZone":{"enable":true},"SixZoneThresholds":{"sat":{"min":10,"max":90,"offset":5,"trapezoidEdgeLeft":"STEP","trapezoidEdgeRight":"SLOPE","satLow":{"min":0,"max":10},"satMid":{"min":31,"max":50},"satHigh":{"min":73,"max":100},"svEnable":true},"val":{"min":20,"max":80,"offset":9,"trapezoidEdgeLeft":"SLOPE","trapezoidEdgeRight":"STEP"}}})");
    unsigned c = 0;
    for (const char *key : {"hueCurve", "satCurve", "valCurve", "satCurveMid", "satCurveHigh"}) {
        auto array = json_object_new_array();
        for (unsigned i = 0; i < 384; ++i)
            payload_check(!json_object_array_add(array, json_object_new_int((i * 13 + c * 29 + 3) % 4096)));
        payload_check(!json_object_object_add(field(picture.get(), "SixZone"), key, array));
        ++c;
    }
    return picture;
}
void parser_and_wire() {
    auto p = picture_fixture();
    const auto wire = native_sixzone(p.get());
    payload_check(wire.size() == 3872 && o82_sixzone_valid(wire.data(), wire.size()));
    payload_check(o82_hdr_u32(wire.data()) == 15);
    payload_check(o82_hdr_u32(wire.data() + 4) == 0xe5cc3319);
    payload_check(o82_hdr_u32(wire.data() + 8) == 0x160c);
    payload_check(o82_hdr_u32(wire.data() + 12) == 0x0ba21555);
    payload_check(o82_hdr_u32(wire.data() + 16) == 0x3a359b33);
    payload_check(o82_hdr_u32(wire.data() + 20) == 0x046904d4);
    payload_check(wire[24] == 1 && wire[25] == 2);
    constexpr unsigned order[]{0, 1, 3, 4, 2};
    for (unsigned i = 0; i < 384; ++i)
        for (unsigned c = 0; c < 5; ++c)
            payload_check(o82_hdr_u16(wire.data() + 32 + i * 10 + c * 2) ==
                          (i * 13 + order[c] * 29 + 3) % 4096);
    auto sat = field(field(p.get(), "SixZoneThresholds"), "sat");
    for (const char *key : {"satLow", "satMid", "satHigh", "svEnable"}) json_object_object_del(sat, key);
    auto six = field(p.get(), "SixZone");
    json_object_object_del(six, "satCurveMid");
    payload_check(!json_object_object_add(six, "satCurveHigh", nullptr));
    const auto legacy = native_sixzone(p.get());
    payload_check(o82_sixzone_valid(legacy.data(), legacy.size()));
    payload_check(o82_hdr_u32(legacy.data()) == 7 && !o82_hdr_u32(legacy.data() + 16) &&
                  !o82_hdr_u32(legacy.data() + 20));
    for (unsigned i = 0; i < 384; ++i) {
        const unsigned low = o82_hdr_u16(legacy.data() + 32 + i * 10 + 2);
        payload_check(o82_hdr_u16(legacy.data() + 32 + i * 10 + 4) == low);
        payload_check(o82_hdr_u16(legacy.data() + 32 + i * 10 + 6) == low);
    }
    for (unsigned offset : {0u, 4u, 8u, 12u, 16u, 20u, 24u, 26u, 28u, 32u, 3870u}) {
        auto bad = wire;
        if (offset >= 32) { bad[offset] = 0; bad[offset + 1] = 16; }
        else if (offset == 4 || offset == 16) bad[offset] = 255;
        else if (offset == 24) bad[offset] = 4;
        else bad[offset] ^= 1;
        payload_check(!o82_sixzone_valid(bad.data(), bad.size()));
    }
    payload_check(!o82_sixzone_valid(nullptr, wire.size()));
    payload_check(!o82_sixzone_valid(wire.data(), wire.size() - 1));
}
void parser_refusal() {
    const auto rejected = [](json_object *p) {
        bool refused = false;
        try { (void)native_sixzone(p); } catch (const std::runtime_error &) { refused = true; }
        payload_check(refused);
    };
    for (const char *key : {"hueCurve", "satCurve", "valCurve", "satCurveMid", "satCurveHigh"}) {
        auto p = picture_fixture(); auto six = field(p.get(), "SixZone");
        payload_check(!json_object_array_put_idx(field(six, key), 7, json_object_new_int(4096)));
        rejected(p.get());
        payload_check(!json_object_object_add(six, key, json_object_new_string("1,2,3")));
        rejected(p.get());
    }
    for (const char *key : {"satLow", "satMid", "satHigh"}) {
        auto p = picture_fixture();
        json_object_object_del(field(field(p.get(), "SixZoneThresholds"), "sat"), key);
        rejected(p.get());
    }
    for (const double value : {-1.0, 0.5, 101.0}) {
        auto p = picture_fixture();
        auto sat = field(field(p.get(), "SixZoneThresholds"), "sat");
        payload_check(!json_object_object_add(sat, "offset", json_object_new_double(value)));
        rejected(p.get());
    }
    auto p = picture_fixture(); auto sat = field(field(p.get(), "SixZoneThresholds"), "sat");
    payload_check(!json_object_object_add(sat, "trapezoidEdgeLeft", json_object_new_string("unknown")));
    rejected(p.get());
    payload_check(!json_object_object_add(sat, "trapezoidEdgeLeft", json_object_new_string("STEP")));
    payload_check(!json_object_object_add(field(sat, "satLow"), "max", json_object_new_int(32)));
    rejected(p.get());
    payload_check(!json_object_object_add(field(p.get(), "SixZone"), "enable", json_object_new_boolean(false)));
    payload_check(native_sixzone(p.get()).empty());
}
void shared_state() {
    const auto wire = native_sixzone(picture_fixture().get());
    constexpr unsigned features[]{1u << 5, 1u << 6, 1u << 7, 1u << 16,
                                  1u << 25, 1u << 26, 1u << 27, 1u << 28};
    for (unsigned subset = 0; subset < 256; ++subset) {
        unsigned other = 0;
        for (unsigned i = 0; i < 8; ++i) if (subset & (1u << i)) other |= features[i];
        for (const unsigned enabled : {0u, 1u << 20}) {
            const unsigned before = other | enabled | 0xe0000000u | 0x103;
            payload_check(o82_sixzone_pa_mode(before, nullptr) == (other | 0x103 | (other ? enabled : 0u)));
            payload_check(o82_sixzone_pa_mode(before, wire.data()) == (other | 0x103 | 0xe0100000u));
        }
    }
    payload_check(o82_sixzone_pa_hold(0xffffabcd, wire.data()) == 0x9bcd);
    payload_check(o82_sixzone_pa_hold(0xffffabcd, nullptr) == 0xffffabcd);
}
} // namespace
extern "C" int __wrap_main() {
    parser_and_wire(); parser_refusal(); shared_state();
    std::cout << "Actual SixZone parser/wire/shared-state: " << payload_checks
              << " synthetic checks passed; no hardware result\n";
    return 0;
}
