// SPDX-License-Identifier: MIT
// Build a private ICC transform from the exact O82 OEM P3 profile; no hardware I/O.
#include <json-c/json.h>
#include <lcms2.h>
#include <openssl/evp.h>
#include <algorithm>
#include <array>
#include <cassert>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
using Vec = std::array<double, 3>;
using Json = std::unique_ptr<json_object, decltype(&json_object_put)>;
using Icc = std::unique_ptr<void, decltype(&cmsCloseProfile)>;
using Pipeline = std::unique_ptr<cmsPipeline, decltype(&cmsPipelineFree)>;
void require(bool ok, const char *reason) { if (!ok) throw std::runtime_error(reason); }
json_object *field(json_object *object, const char *name) {
    json_object *value = nullptr;
    require(object && json_object_is_type(object, json_type_object) &&
            json_object_object_get_ex(object, name, &value), "missing profile field");
    return value;
}
bool enabled(json_object *object) {
    auto value = field(object, "enable");
    require(json_object_is_type(value, json_type_boolean) ||
            (json_object_is_type(value, json_type_int) &&
             (json_object_get_int64(value) == 0 || json_object_get_int64(value) == 1)),
            "invalid enable field");
    return json_object_get_boolean(value);
}
std::string_view text_field(json_object *object, const char *name) {
    auto value = field(object, name);
    require(json_object_is_type(value, json_type_string), "non-string profile metadata");
    return {json_object_get_string(value), static_cast<size_t>(json_object_get_string_len(value))};
}
double number(json_object *value) {
    require(json_object_is_type(value, json_type_int) || json_object_is_type(value, json_type_double),
            "non-numeric profile value");
    const double result = json_object_get_double(value);
    require(std::isfinite(result), "non-finite profile value");
    return result;
}
Json parse(std::string_view text) {
    std::unique_ptr<json_tokener, decltype(&json_tokener_free)> tokener(json_tokener_new_ex(32), json_tokener_free);
    require(bool(tokener), "JSON allocation failed");
    json_tokener_set_flags(tokener.get(), JSON_TOKENER_STRICT);
    Json value(json_tokener_parse_ex(tokener.get(), text.data(), static_cast<int>(text.size())), json_object_put);
    require(json_tokener_get_error(tokener.get()) == json_tokener_success && value &&
            json_object_is_type(value.get(), json_type_object), "invalid profile JSON");
    const auto end = json_tokener_get_parse_end(tokener.get());
    require(text.substr(end).find_first_not_of(" \r\n\t") == std::string_view::npos, "trailing profile data");
    return value;
}
Json decode(json_object *profile, const char *name) {
    auto value = field(profile, name);
    require(json_object_is_type(value, json_type_string), "non-string profile payload");
    const std::string_view hex(json_object_get_string(value), json_object_get_string_len(value));
    require(!hex.empty() && hex.size() <= 2 * 1024 * 1024 && hex.size() % 2 == 0, "invalid hex payload length");
    std::string raw;
    raw.reserve(hex.size() / 2);
    for (size_t at = 0; at < hex.size(); at += 2) {
        unsigned byte;
        const auto [end, error] = std::from_chars(hex.data() + at, hex.data() + at + 2, byte, 16);
        require(error == std::errc() && end == hex.data() + at + 2, "invalid hex payload");
        raw.push_back(static_cast<char>(byte));
    }
    Json selected(nullptr, json_object_put);
    std::string canonical;
    for (int encoding = 0; encoding < 3; ++encoding) {
        std::string candidate = raw;
        if (encoding)
            for (size_t at = encoding - 1; at + 1 < candidate.size(); at += 2)
                std::swap(candidate[at], candidate[at + 1]);
        Json parsed(nullptr, json_object_put);
        try { parsed = parse(candidate); } catch (const std::runtime_error &) { continue; }
        const std::string normalized = json_object_to_json_string_ext(parsed.get(), JSON_C_TO_STRING_PLAIN);
        require(!selected || canonical == normalized, "ambiguous payload encoding");
        canonical = normalized;
        selected = std::move(parsed);
    }
    require(bool(selected), "unrecognized payload encoding");
    return selected;
}
std::vector<double> curve(json_object *object, const char *name, size_t count, double maximum) {
    auto array = field(object, name);
    require(json_object_is_type(array, json_type_array) && json_object_array_length(array) == count,
            "invalid curve length");
    std::vector<double> result;
    for (size_t at = 0; at < count; ++at) {
        const double sample = number(json_object_array_get_idx(array, at));
        require(sample >= 0 && sample <= maximum && sample == std::floor(sample), "invalid curve value");
        require(result.empty() || sample / maximum >= result.back(), "non-monotonic curve");
        result.push_back(sample / maximum);
    }
    return result;
}
std::vector<Vec> cube(json_object *object, unsigned maximum) {
    auto array = field(object, "mapFine");
    require(json_object_is_type(array, json_type_array) && json_object_array_length(array) == 4913,
            "invalid gamut table length");
    std::vector<Vec> result;
    for (size_t at = 0; at < 4913; ++at) {
        auto entry = json_object_array_get_idx(array, at);
        require(json_object_is_type(entry, json_type_string), "invalid gamut entry");
        std::string_view text(json_object_get_string(entry), json_object_get_string_len(entry));
        Vec sample{};
        for (size_t channel = 0; channel < 3; ++channel) {
            unsigned value;
            const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
            require(error == std::errc() && value <= maximum, "invalid gamut value");
            sample[channel] = value / double(maximum);
            if (channel < 2) {
                require(end < text.data() + text.size() && *end == ',', "invalid gamut separator");
                text.remove_prefix(end - text.data() + 1);
            } else require(end == text.data() + text.size(), "trailing gamut data");
        }
        result.push_back(sample);
    }
    return result;
}
double lookup(const std::vector<double> &table, double value) {
    const double at = std::clamp(value, 0.0, 1.0) * (table.size() - 1);
    const auto lower = static_cast<size_t>(at);
    const double fraction = at - lower;
    return table[lower] * (1 - fraction) + table[std::min(lower + 1, table.size() - 1)] * fraction;
}
struct Profile {
    std::array<std::vector<double>, 3> igc, gc;
    std::vector<Vec> gamut;
    Vec map(Vec rgb) const {
        std::array<unsigned, 3> lower{};
        Vec fraction{}, result{};
        for (size_t channel = 0; channel < 3; ++channel) {
            const double at = lookup(igc[channel], rgb[channel]) * 16;
            lower[channel] = std::min(static_cast<unsigned>(at), 15u);
            fraction[channel] = at - lower[channel];
        }
        for (unsigned corner = 0; corner < 8; ++corner) {
            unsigned index = 0, stride = 1;
            double weight = 1;
            for (size_t channel = 0; channel < 3; ++channel) {
                const unsigned upper = (corner >> channel) & 1;
                index += (lower[channel] + upper) * stride;
                stride *= 17;
                weight *= upper ? fraction[channel] : 1 - fraction[channel];
            }
            for (size_t channel = 0; channel < 3; ++channel) result[channel] += weight * gamut[index][channel];
        }
        for (size_t channel = 0; channel < 3; ++channel) result[channel] = lookup(gc[channel], result[channel]);
        return result;
    }
};
Profile load(json_object *document, const char *panel) {
    auto modes = field(document, panel);
    auto standard = field(modes, "standard_P3");
    auto applicability = field(standard, "Applicability");
    require(text_field(standard, "DynamicRange") == "SDR" &&
            text_field(applicability, "ColorPrimaries") == "P3" &&
            text_field(applicability, "GammaTransfer") == "sRGB",
            "unsupported profile applicability");
    auto igc = decode(standard, "PostBlendIGC");
    auto gc = decode(standard, "PostBlendGC");
    auto gamut = decode(standard, "PostBlendGamut");
    require(enabled(igc.get()) && enabled(gc.get()) && enabled(gamut.get()), "inactive color pipeline");
    require(!json_object_get_boolean(field(igc.get(), "ditherEnable")) &&
            number(field(gc.get(), "bitsRounding")) == 10, "unsupported dither or precision");
    for (const char *name : {"PostBlendPCC", "PostBlendDE", "PostBlendDither"}) {
        auto decoded = decode(standard, name);
        require(!enabled(decoded.get()), "unsupported active color operation");
    }
    auto pa = decode(standard, "PostBlendPa");
    for (const char *name : {"cont", "hue", "sat", "satThresh", "val"})
        require(number(field(pa.get(), name)) == 0, "unsupported picture adjustment");
    for (const char *name : {"SixZone", "MemColFol", "MemColSkin", "MemColSky"})
        require(!enabled(field(pa.get(), name)), "unsupported picture adjustment block");
    auto native = decode(field(modes, "expert_native"), "PostBlendGamut");
    require(!enabled(native.get()), "unexpected native gamut state");
    const auto identity = cube(native.get(), 4096);
    for (unsigned blue = 0; blue < 17; ++blue)
        for (unsigned green = 0; green < 17; ++green)
            for (unsigned red = 0; red < 17; ++red)
                require(identity[(blue * 17 + green) * 17 + red] == Vec{red / 16.0, green / 16.0, blue / 16.0},
                        "unrecognized gamut axis order");
    Profile result;
    const char *channels[] = {"lutR", "lutG", "lutB"};
    for (size_t channel = 0; channel < 3; ++channel) {
        result.igc[channel] = curve(igc.get(), channels[channel], 257, 4095);
        require(result.igc[channel].back() == 1, "unexpected IGC endpoint");
        result.gc[channel] = curve(gc.get(), channels[channel], 1024, 1023);
    }
    result.gamut = cube(gamut.get(), 4095);
    return result;
}
Icc p3_reference() {
    const cmsCIExyY white{0.3127, 0.3290, 1};
    const cmsCIExyYTRIPLE primaries{{0.68, 0.32, 1}, {0.265, 0.69, 1}, {0.15, 0.06, 1}};
    const double parameters[]{2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045};
    cmsToneCurve *curve = cmsBuildParametricToneCurve(nullptr, 4, parameters);
    require(curve, "tone curve allocation failed");
    cmsToneCurve *curves[]{curve, curve, curve};
    Icc result(cmsCreateRGBProfile(&white, &primaries, curves), cmsCloseProfile);
    cmsFreeToneCurve(curve);
    require(bool(result), "P3 reference allocation failed");
    return result;
}
cmsInt32Number sample(const cmsUInt16Number in[], cmsUInt16Number out[], void *context) {
    auto result = static_cast<const Profile *>(context)->map({in[0] / 65535.0, in[1] / 65535.0, in[2] / 65535.0});
    for (size_t channel = 0; channel < 3; ++channel)
        out[channel] = static_cast<cmsUInt16Number>(std::lround(std::clamp(result[channel], 0.0, 1.0) * 65535));
    return 1;
}
Icc make_icc(const Profile &factory) {
    auto reference = p3_reference();
    Icc output(cmsCreateProfilePlaceholder(nullptr), cmsCloseProfile);
    require(bool(output), "ICC allocation failed");
    cmsSetProfileVersion(output.get(), 4.3);
    cmsSetDeviceClass(output.get(), cmsSigDisplayClass);
    cmsSetColorSpace(output.get(), cmsSigRgbData);
    cmsSetPCS(output.get(), cmsSigXYZData);
    cmsSetHeaderRenderingIntent(output.get(), INTENT_RELATIVE_COLORIMETRIC);
    for (auto tag : {cmsSigMediaWhitePointTag, cmsSigChromaticAdaptationTag,
                    cmsSigRedColorantTag, cmsSigGreenColorantTag, cmsSigBlueColorantTag,
                    cmsSigRedTRCTag, cmsSigGreenTRCTag, cmsSigBlueTRCTag})
        require(cmsReadTag(reference.get(), tag) && cmsWriteTag(output.get(), tag, cmsReadTag(reference.get(), tag)), "ICC reference tag failed");
    const cmsCIEXYZ *r = static_cast<const cmsCIEXYZ *>(cmsReadTag(reference.get(), cmsSigRedColorantTag));
    const cmsCIEXYZ *g = static_cast<const cmsCIEXYZ *>(cmsReadTag(reference.get(), cmsSigGreenColorantTag));
    const cmsCIEXYZ *b = static_cast<const cmsCIEXYZ *>(cmsReadTag(reference.get(), cmsSigBlueColorantTag));
    const double determinant = r->X * (g->Y * b->Z - g->Z * b->Y) - g->X * (r->Y * b->Z - r->Z * b->Y) + b->X * (r->Y * g->Z - r->Z * g->Y);
    require(std::abs(determinant) > 1e-9, "singular P3 matrix");
    double matrix[]{g->Y*b->Z-g->Z*b->Y, b->X*g->Z-g->X*b->Z, g->X*b->Y-b->X*g->Y,
                    b->Y*r->Z-r->Y*b->Z, r->X*b->Z-b->X*r->Z, b->X*r->Y-r->X*b->Y,
                    r->Y*g->Z-g->Y*r->Z, g->X*r->Z-r->X*g->Z, r->X*g->Y-g->X*r->Y};
    for (double &value : matrix) value *= (65535.0 / 32768.0) / determinant;
    Pipeline pipeline(cmsPipelineAlloc(nullptr, 3, 3), cmsPipelineFree);
    require(bool(pipeline), "pipeline allocation failed");
    cmsToneCurve *identity = cmsBuildGamma(nullptr, 1);
    cmsToneCurve *inverse = cmsReverseToneCurveEx(4096, static_cast<const cmsToneCurve *>(cmsReadTag(reference.get(), cmsSigRedTRCTag)));
    require(identity && inverse, "pipeline curve allocation failed");
    cmsToneCurve *identities[]{identity, identity, identity}, *inverses[]{inverse, inverse, inverse};
    auto insert = [&](cmsStage *stage) {
        require(stage && cmsPipelineInsertStage(pipeline.get(), cmsAT_END, stage), "pipeline stage failed");
    };
    insert(cmsStageAllocToneCurves(nullptr, 3, identities));
    insert(cmsStageAllocMatrix(nullptr, 3, 3, matrix, nullptr));
    insert(cmsStageAllocToneCurves(nullptr, 3, inverses));
    auto clut = cmsStageAllocCLut16bit(nullptr, 65, 3, 3, nullptr);
    require(clut && cmsStageSampleCLut16bit(clut, sample, const_cast<Profile *>(&factory), 0), "ICC gamut sampling failed");
    insert(clut);
    insert(cmsStageAllocToneCurves(nullptr, 3, identities));
    cmsFreeToneCurve(identity);
    cmsFreeToneCurve(inverse);
    require(cmsWriteTag(output.get(), cmsSigBToA1Tag, pipeline.get()) &&
            cmsWriteTag(output.get(), cmsSigBToA0Tag, pipeline.get()), "ICC transform tag failed");
    auto text = cmsMLUalloc(nullptr, 1);
    require(text && cmsMLUsetASCII(text, "en", "US", "O82 OEM P3 mapping (nominal, not optically calibrated)") &&
            cmsWriteTag(output.get(), cmsSigProfileDescriptionTag, text), "ICC description failed");
    cmsMLUfree(text);
    return output;
}
std::string read_file(const char *path) {
    const int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    require(fd >= 0, "cannot open OEM profile");
    struct stat status{};
    if (fstat(fd, &status) || !S_ISREG(status.st_mode) || status.st_size <= 0 || status.st_size > 32 * 1024 * 1024) {
        close(fd); throw std::runtime_error("invalid OEM profile file");
    }
    std::string data(static_cast<size_t>(status.st_size), '\0');
    size_t at = 0;
    while (at < data.size()) {
        const ssize_t bytes = read(fd, data.data() + at, data.size() - at);
        if (bytes <= 0) { close(fd); throw std::runtime_error("OEM profile read failed"); }
        at += bytes;
    }
    close(fd);
    return data;
}
std::string sha256(std::string_view data) {
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned length = 0;
    require(EVP_Digest(data.data(), data.size(), hash, &length, EVP_sha256(), nullptr) && length == 32, "SHA-256 failed");
    std::string result;
    for (unsigned at = 0; at < length; ++at) {
        result.push_back("0123456789abcdef"[hash[at] >> 4]);
        result.push_back("0123456789abcdef"[hash[at] & 15]);
    }
    return result;
}
void save(cmsHPROFILE profile, const char *path) {
    cmsUInt32Number length = 0;
    require(cmsSaveProfileToMem(profile, nullptr, &length) && length <= 8 * 1024 * 1024, "ICC serialization failed");
    std::vector<unsigned char> data(length);
    require(cmsSaveProfileToMem(profile, data.data(), &length), "ICC serialization failed");
    const int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd >= 0, "cannot create new ICC file (existing files are retained)");
    size_t at = 0;
    bool ok = true;
    while (at < length) {
        const ssize_t bytes = write(fd, data.data() + at, length - at);
        if (bytes <= 0) { ok = false; break; }
        at += bytes;
    }
    if (fsync(fd)) ok = false;
    if (close(fd)) ok = false;
    if (!ok) { unlink(path); throw std::runtime_error("ICC write failed"); }
}
void self_test() {
    Profile identity;
    for (size_t channel = 0; channel < 3; ++channel) {
        for (unsigned at = 0; at < 257; ++at) identity.igc[channel].push_back(at / 256.0);
        for (unsigned at = 0; at < 1024; ++at) identity.gc[channel].push_back(at / 1023.0);
    }
    for (unsigned blue = 0; blue < 17; ++blue)
        for (unsigned green = 0; green < 17; ++green)
            for (unsigned red = 0; red < 17; ++red) identity.gamut.push_back({red / 16.0, green / 16.0, blue / 16.0});
    const std::array<Vec, 6> inputs{{{0,0,0}, {1,1,1}, {0.1,0.2,0.3}, {1,0,0}, {0,1,0}, {0,0,1}}};
    for (const Vec input : inputs) {
        const auto output = identity.map(input);
        for (size_t channel = 0; channel < 3; ++channel) assert(std::abs(output[channel] - input[channel]) < 1e-12);
    }
    for (const char *hex : {"7b2261223a317d", "227b2261313a7d", "7b61223a227d31"}) {
        auto original = parse(std::string("{\"payload\":\"") + hex + "\"}");
        auto decoded = decode(original.get(), "payload");
        assert(number(field(decoded.get(), "a")) == 1);
    }
    for (const char *json : {"{\"payload\":null}", "{\"payload\":\"z0\"}", "{\"payload\":\"0\"}"}) {
        bool refused = false;
        try { auto original = parse(json); auto invalid = decode(original.get(), "payload"); (void)invalid; }
        catch (const std::runtime_error &) { refused = true; }
        assert(refused);
    }
    for (const char *json : {"{\"lut\":[0,2,1]}", "{\"lut\":[0,1,3]}", "{\"lut\":[0,1]}"}) {
        bool refused = false;
        try { auto original = parse(json); (void)curve(original.get(), "lut", 3, 2); }
        catch (const std::runtime_error &) { refused = true; }
        assert(refused);
    }
    bool refused = false;
    try { auto invalid = parse("{} trailing"); (void)invalid; } catch (const std::runtime_error &) { refused = true; }
    assert(refused);
    auto reference = p3_reference();
    auto profile = make_icc(identity);
    cmsUInt32Number size = 0;
    assert(cmsSaveProfileToMem(profile.get(), nullptr, &size) && size > 1000);
    std::vector<unsigned char> bytes(size);
    assert(cmsSaveProfileToMem(profile.get(), bytes.data(), &size));
    Icc reopened(cmsOpenProfileFromMem(bytes.data(), size), cmsCloseProfile);
    assert(reopened && cmsGetPCS(reopened.get()) == cmsSigXYZData && cmsIsTag(reopened.get(), cmsSigBToA1Tag));
    auto transform = cmsCreateTransform(reference.get(), TYPE_RGB_DBL, reopened.get(), TYPE_RGB_DBL,
                                        INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE);
    assert(transform);
    for (const Vec input : inputs) {
        Vec output{};
        cmsDoTransform(transform, input.data(), output.data(), 1);
        for (size_t channel = 0; channel < 3; ++channel) assert(std::abs(output[channel] - input[channel]) < 0.004);
    }
    cmsDeleteTransform(transform);
    assert(sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    std::cout << "Decoder, gamut axis/interpolation, ICC XYZ/P3 roundtrip and SHA-256 checks passed\n";
}
}
int main(int argc, char **argv) {
    try {
        if (argc == 2 && std::string_view(argv[1]) == "--self-test") { self_test(); return 0; }
        require(argc == 3, "usage: uke-o82-color-profile OEM_QDCM_JSON NEW_PRIVATE_ICC");
        const auto data = read_file(argv[1]);
        const auto hash = sha256(data);
        const char *panel = nullptr;
        if (hash == "bd88eb94134e5f62c05eebaa0a9e4b5267968363f72f440018b98a15d1bd9122") panel = "xiaomi_o82_36_02_0a_vid_mode_dualdsi_dsc_panel";
        if (hash == "2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8") panel = "xiaomi_o82_42_02_0b_vid_mode_dualdsi_dsc_panel";
        require(panel, "unreviewed OEM profile hash");
        auto document = parse(data);
        auto factory = load(document.get(), panel);
        auto profile = make_icc(factory);
        save(profile.get(), argv[2]);
        std::cout << "Generated private " << panel << " P3 ICC mapping; optical calibration and HDR10/EDR acceptance remain unmeasured\n";
    } catch (const std::exception &error) {
        std::cerr << "O82 profile: " << error.what() << '\n';
        return 1;
    }
}
