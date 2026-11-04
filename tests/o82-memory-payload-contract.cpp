// SPDX-License-Identifier: MIT
// Synthetic JSON -> actual generator -> actual C loader and command encoder.
#include "o82-color-profile.cpp"
extern "C" {
#include <linux/firmware.h>
#include "dpu_o82_profiles.h"
#include "dpu_o82_lutbus.h"
}

namespace {
unsigned memory_checks, complete_cases, input_cases, encoded_cases, edge_differences;
unsigned fixture_panel, fixture_requests, fixture_releases;
const char *memory_stage = "complete pipeline";
firmware memory_firmware{};
std::array<unsigned char, DPU_O82_LUTBUS_MAX_BYTES> memory_commands;
constexpr const char *region_names[]{"MemColSkin", "MemColSky", "MemColFol"};
void memory_check(bool ok) {
    ++memory_checks;
    if (!ok) throw std::runtime_error("memory JSON pipeline check " + std::to_string(memory_checks) + " failed");
}
void set_boolean(json_object *object, const char *key, bool value) {
    memory_check(!json_object_object_add(object, key, json_object_new_boolean(value)));
}
void set_number(json_object *object, const char *key, double value) {
    memory_check(!json_object_object_add(object, key, json_object_new_double(value)));
}
void set_text(json_object *object, const char *key, const char *value) {
    memory_check(!json_object_object_add(object, key, json_object_new_string(value)));
}
json_object *hex_payload(json_object *value) {
    const std::string raw = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
    constexpr const char digits[] = "0123456789abcdef";
    std::string result;
    for (unsigned char c : raw) { result += digits[c >> 4]; result += digits[c & 15]; }
    return json_object_new_string_len(result.data(), result.size());
}
Json memory_picture() {
    auto p = parse(R"({"hue":0,"sat":0,"satThresh":0,"val":0,"cont":0,"SixZone":{"enable":false}})");
    for (unsigned i = 0; i < 3; i++) {
        auto r = parse(R"({"enable":false,"blendingEnable":true,"protectContrast":false,"protectVsSixZone":false,"hue":{"adj":0,"min":0,"max":90,"mid":90,"protect":false},"sat":{"adj":0,"min":12.5,"max":87.25,"mid":0,"protect":false,"trapezoidEdgeLeft":"STEP","trapezoidEdgeRight":"SLOPE"},"val":{"adj":0,"min":3.125,"max":98.5,"mid":0,"protect":false,"trapezoidEdgeLeft":"SLOPE","trapezoidEdgeRight":"STEP"}})");
        auto h = field(r.get(), "hue"), s = field(r.get(), "sat"), v = field(r.get(), "val");
        set_number(h, "adj", i == 1 ? 45 : i == 2 ? -45 : 0);
        set_number(h, "min", i * 45); set_number(h, "max", 90 + i * 45); set_number(h, "mid", 90 + i * 90);
        if (i) {
            set_number(s, "adj", i == 1 ? 12.5 : -25); set_number(v, "adj", i == 1 ? -25 : 50);
            set_number(s, "min", 10 + i * 10); set_number(s, "max", 90 - i * 10); set_number(s, "mid", i * 20);
            set_number(v, "min", i * 10); set_number(v, "max", 100 - i * 10); set_number(v, "mid", i * 40);
        }
        memory_check(!json_object_object_add(p.get(), region_names[i], r.release()));
    }
    return p;
}
o82::MemoryColorInput reference_input(unsigned i) {
    // Independent typed fields: do not read the JSON under test to derive them.
    o82::MemoryColorInput x;
    x.hue_adjustment = i == 1 ? 45 : i == 2 ? -45 : 0;
    x.hue_extent = 90 + i * 90; x.hue_minimum = i * 45; x.hue_maximum = 90 + i * 45;
    x.saturation_adjustment = i == 1 ? 12.5f : i == 2 ? -25.0f : 0.0f;
    x.value_adjustment = i == 1 ? -25.0f : i == 2 ? 50.0f : 0.0f;
    x.saturation_extent = i * 20; x.value_extent = i * 40;
    x.saturation_minimum = i ? float(10 + i * 10) : 12.5f;
    x.saturation_maximum = i ? float(90 - i * 10) : 87.25f;
    x.value_minimum = i ? float(i * 10) : 3.125f;
    x.value_maximum = i ? float(100 - i * 10) : 98.5f;
    x.saturation_hold_control = i ? 2 : 0; x.value_hold_control = 1;
    return x;
}
void expect_region(const unsigned char *p, const o82::MemoryColorData &x) {
    const std::array<unsigned, 8> expected{x.adjust_p0, x.adjust_p1, x.adjust_p2, x.blend_gain,
        unsigned(x.saturation_hold) | (unsigned(x.value_hold) << 2), x.hue_region, x.saturation_region, x.value_region};
    for (unsigned i = 0; i < expected.size(); i++) memory_check(o82_hdr_u32(p + i * 4) == expected[i]);
}
Json memory_document() {
    auto mode = parse(R"({"Applicability":{"ColorPrimaries":"P3","GammaTransfer":"sRGB"},"DynamicRange":"SDR"})");
    for (const char *op : {"PostBlendIGC", "PostBlendGC"}) {
        const bool igc = std::string_view(op) == "PostBlendIGC";
        auto table = parse(igc ? R"({"enable":true,"ditherEnable":false})" : R"({"enable":true,"bitsRounding":10})");
        const unsigned count = igc ? 257 : 1024, maximum = igc ? 4095 : 1023;
        for (const char *channel : {"lutR", "lutG", "lutB"}) {
            auto samples = json_object_new_array();
            for (unsigned at = 0; at < count; at++)
                memory_check(!json_object_array_add(samples, json_object_new_int(std::lround(at * double(maximum) / (count - 1)))));
            memory_check(!json_object_object_add(table.get(), channel, samples));
        }
        memory_check(!json_object_object_add(mode.get(), op, hex_payload(table.get())));
    }
    auto gamut = parse(R"({"enable":false})");
    memory_check(!json_object_object_add(mode.get(), "PostBlendGamut", hex_payload(gamut.get())));
    auto document = parse(R"({"synthetic":{}})");
    memory_check(!json_object_object_add(field(document.get(), "synthetic"), "standard_P3", mode.release()));
    return document;
}
void complete_pipeline() {
    constexpr const char *hashes[]{
        "bd88eb94134e5f62c05eebaa0a9e4b5267968363f72f440018b98a15d1bd9122",
        "2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8"};
    auto document = memory_document();
    auto mode = field(field(document.get(), "synthetic"), "standard_P3");
    device dev{};
    for (unsigned supplier = 0; supplier < 2; supplier++) {
        fixture_panel = supplier ? 0x42 : 0x36;
        for (unsigned mask = 0; mask < 8; mask++) for (unsigned protection = 0; protection < 64; protection++) {
            auto picture = memory_picture();
            for (unsigned i = 0; i < 3; i++) set_boolean(field(picture.get(), region_names[i]), "enable", mask & (1U << i));
            // Place protection on each region in turn, including inactive ones.
            auto owner = field(picture.get(), region_names[protection % 3]);
            set_boolean(field(owner, "hue"), "protect", protection & 1);
            set_boolean(field(owner, "sat"), "protect", protection & 2);
            set_boolean(field(owner, "val"), "protect", protection & 4);
            set_boolean(owner, "protectContrast", protection & 8);
            set_boolean(owner, "protectVsSixZone", protection & 16);
            set_boolean(owner, "blendingEnable", !(protection & 32));
            const auto wire = native_memory(picture.get());
            memory_check(wire.size() == O82_MEMORY_BYTES && o82_memory_valid(wire.data(), wire.size()));
            memory_check(o82_hdr_u32(wire.data()) == mask && o82_hdr_u32(wire.data() + 4) == protection);
            for (unsigned i = 0; i < 3; i++) {
                const auto *p = o82_memory_region(wire.data(), i);
                if (mask & (1U << i)) {
                    o82::MemoryColorData expected;
                    memory_check(o82::compile_memory_color(reference_input(i), expected) == o82::MemoryColorError::none);
                    expect_region(p, expected);
                    if (!i) memory_check(o82_hdr_u32(p + 20) == 0x01800000 &&
                        o82_hdr_u32(p + 24) == 0x0008de1f && o82_hdr_u32(p + 28) == 0x0008fb07);
                } else memory_check(o82_color_fw_zero(p, O82_MEMORY_REGION_BYTES));
            }
            memory_check(!json_object_object_add(mode, "PostBlendPa", hex_payload(picture.get())));
            const auto bundle = native_presets(document.get(), "synthetic", fixture_panel, hashes[supplier]);
            memory_check(o82_hdr_u32(bundle.data() + 8) == 5 && !std::memcmp(bundle.data(), "O82COLR5", 8));
            const auto *record = o82_color_fw_record(bundle.data(), 0);
            memory_check(!o82_hdr_u32(record + 76) &&
                !!(o82_hdr_u32(record + 72) & O82_COLOR_OP_MEMORY) == !!(mask || protection));
            memory_check(o82_hdr_u32(record + 156) == wire.size() &&
                !std::memcmp(bundle.data() + o82_hdr_u32(record + 152), wire.data(), wire.size()));
            memory_firmware = {bundle.data(), bundle.size()};
            dpu_o82_profiles profiles{};
            const unsigned before = fixture_requests;
            memory_check(!dpu_o82_profiles_load(&profiles, &dev, fixture_panel) && fixture_requests == before + 1);
            for (unsigned wide = 0; wide < 2; wide++) for (unsigned pq = 0; pq < 2; pq++) {
                dpu_o82_color_input input{};
                memory_check(!dpu_o82_profiles_input(&profiles, wide, pq, &input));
                memory_check(input.memory_bytes == wire.size() && !std::memcmp(input.memory, wire.data(), wire.size()));
                for (unsigned pair : {3u, 5u, 6u}) {
                    size_t bytes = 0;
                    memory_check(!dpu_o82_lutbus_build(&input, pair, memory_commands.data(), memory_commands.size(), &bytes));
                    memory_check(bytes == DPU_O82_LUTBUS_MEMORY_BYTES &&
                        o82_hdr_u32(memory_commands.data() + 4) == pair << 17);
                    encoded_cases++;
                }
                input_cases++;
            }
            dpu_o82_profiles_unload(&profiles);
            memory_check(!profiles.fw); complete_cases++;
        }
    }
    memory_check(fixture_requests == complete_cases && fixture_releases == complete_cases);
}
void edge_cases() {
    for (unsigned i = 0; i < 3; i++) for (unsigned component = 0; component < 2; component++)
        for (unsigned left = 0; left < 2; left++) for (unsigned right = 0; right < 2; right++) {
            auto p = memory_picture(); auto r = field(p.get(), region_names[i]); set_boolean(r, "enable", true);
            auto c = field(r, component ? "val" : "sat");
            set_text(c, "trapezoidEdgeLeft", left ? "STEP" : "SLOPE");
            set_text(c, "trapezoidEdgeRight", right ? "STEP" : "SLOPE");
            const auto wire = native_memory(p.get());
            const unsigned actual = (o82_hdr_u32(o82_memory_region(wire.data(), i) + 16) >> (component * 2)) & 3;
            const unsigned expected = !i && !component ? (left ? 3 : 0) : left | (right << 1);
            memory_check(actual == expected);
            edge_differences += actual != (left | (right << 1));
        }
    memory_check(edge_differences == 2);
}
void rejected(json_object *picture) {
    bool refused = false;
    try { (void)native_memory(picture); } catch (const std::runtime_error &) { refused = true; }
    memory_check(refused);
}
void malformed_fields() {
    for (const char *name : region_names) {
        for (const char *component : {"hue", "sat", "val"}) for (const char *key : {"adj", "min", "max", "mid"})
            for (unsigned defect = 0; defect < 6; defect++) {
                auto p = memory_picture(); auto c = field(field(p.get(), name), component);
                if (!defect) json_object_object_del(c, key);
                if (defect == 1) set_text(c, key, "0");
                if (defect == 2) set_boolean(c, key, false);
                if (defect == 3) set_number(c, key, INFINITY);
                if (defect == 4) set_number(c, key, NAN);
                if (defect == 5) set_number(c, key, 1e100);
                rejected(p.get());
            }
        for (const char *component : {"hue", "sat", "val"}) {
            const bool hue = std::string_view(component) == "hue";
            for (const char *key : {"adj", "min", "max", "mid"}) {
                if (!hue && std::string_view(key) != "mid") continue;
                const bool mid = std::string_view(key) == "mid";
                for (double bad : {0.5, mid ? -1.0 : -2147483649.0, mid ? 4294967296.0 : 2147483648.0}) {
                    auto p = memory_picture(); set_number(field(field(p.get(), name), component), key, bad); rejected(p.get());
                }
            }
            if (hue) continue;
            for (const char *key : {"trapezoidEdgeLeft", "trapezoidEdgeRight"}) {
                auto p = memory_picture(); set_text(field(field(p.get(), name), component), key, "UNKNOWN"); rejected(p.get());
            }
        }
        for (unsigned selector = 0; selector < 7; selector++) for (unsigned defect = 0; defect < 4; defect++) {
            auto p = memory_picture(); auto r = field(p.get(), name);
            const char *key = selector == 0 ? "enable" : selector == 1 ? "blendingEnable" :
                selector == 2 ? "protectContrast" : selector == 3 ? "protectVsSixZone" : "protect";
            auto owner = selector < 4 ? r : field(r, selector == 4 ? "hue" : selector == 5 ? "sat" : "val");
            if (!defect) json_object_object_del(owner, key);
            if (defect == 1) set_text(owner, key, "false");
            if (defect == 2) memory_check(!json_object_object_add(owner, key, json_object_new_int(2)));
            if (defect == 3) memory_check(!json_object_object_add(owner, key, nullptr));
            rejected(p.get());
        }
    }
    auto p = memory_picture(); auto r = field(p.get(), "MemColSkin"); set_boolean(r, "enable", true);
    for (double extent : {0.0, 360.0, 2147483647.0, 2147483648.0, 4294967295.0}) {
        set_number(field(r, "hue"), "mid", extent);
        const auto wire = native_memory(p.get());
        const unsigned expected = extent >= 2147483648.0 || !extent ? 8 : 1536;
        memory_check((o82_hdr_u32(o82_memory_region(wire.data(), 0)) & 0x7ff) == expected);
    }
    for (int rounding : {FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO}) {
        memory_check(!std::fesetround(rounding)); rejected(p.get());
    }
    memory_check(!std::fesetround(FE_TONEAREST));
}
} // namespace
extern "C" int request_firmware_direct(const firmware **fw, const char *name, device *dev) {
    const std::string expected = fixture_panel == 0x42 ? "qcom/sm7675/uke/o82-42-color-v5.bin" :
        "qcom/sm7675/uke/o82-36-color-v5.bin";
    memory_check(dev && expected == name); fixture_requests++; *fw = &memory_firmware; return 0;
}
extern "C" void release_firmware(const firmware *fw) { memory_check(fw == &memory_firmware); fixture_releases++; }
extern "C" int __wrap_main() {
    try {
        complete_pipeline(); memory_stage = "edges"; edge_cases();
        memory_stage = "malformed fields"; malformed_fields();
        std::cout << "Actual memory JSON/v5/kernel pipeline: " << complete_cases << " complete cases, "
            << input_cases << " table inputs, " << encoded_cases << " paired command streams, " << memory_checks
            << " checks passed; both suppliers, disabled-region protection, explicit neutral, malformed fields and "
            << edge_differences << " skin-edge difference controls; synthetic only\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "Memory pipeline " << memory_stage << ", " << complete_cases << " complete cases: " << error.what() << '\n';
        return 1;
    }
}
