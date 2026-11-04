// SPDX-License-Identifier: MIT
// Compile private O82 color data, with optional read-only stock preparation.
#include <json-c/json.h>
#include <lcms2.h>
#include <openssl/evp.h>
#include <algorithm>
#include <array>
#include <bit>
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
#include "uke-o82-hdr-format.h"
#include "o82-regdma.h"
#include "o82-color-firmware.h"
#include "o82-sixzone.h"
#include "o82-hsic.h"
#include "o82-memory-color.h"
#include "o82-stock-profile.hpp"

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
bool boolean_field(json_object *object, const char *key) {
    auto value = field(object, key);
    require(json_object_is_type(value, json_type_boolean) ||
            (json_object_is_type(value, json_type_int) &&
             (json_object_get_int64(value) == 0 || json_object_get_int64(value) == 1)),
            "invalid boolean field");
    return json_object_get_boolean(value);
}
bool enabled(json_object *object) { return boolean_field(object, "enable"); }
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
    Vec gamut_map(Vec rgb) const {
        std::array<unsigned, 3> lower{};
        Vec fraction{}, result{};
        for (size_t channel = 0; channel < 3; ++channel) {
            // OEM FillRgbInEntries uses 0,256,...,3840,4095, with R fastest.
            const double code = std::clamp(rgb[channel], 0.0, 1.0) * 4095;
            lower[channel] = std::min(static_cast<unsigned>(code) / 256, 15u);
            fraction[channel] = (code - lower[channel] * 256) /
                                (lower[channel] == 15 ? 255.0 : 256.0);
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
        return result;
    }
    Vec map(Vec rgb) const {
        for (size_t channel = 0; channel < 3; ++channel) rgb[channel] = lookup(igc[channel], rgb[channel]);
        auto result = gamut_map(rgb);
        for (size_t channel = 0; channel < 3; ++channel) result[channel] = lookup(gc[channel], result[channel]);
        return result;
    }
};
double gamut_knot(unsigned at) {
    require(at <= 16, "invalid gamut knot");
    return std::min(at * 256, 4095u) / 4095.0;
}
Profile load_pipeline(json_object *igc, json_object *gc, json_object *gamut) {
    require(enabled(igc) && enabled(gc), "inactive IGC or output gamma");
    require(number(field(gc, "bitsRounding")) == 10, "unsupported output precision");
    Profile result;
    const char *channels[] = {"lutR", "lutG", "lutB"};
    for (size_t channel = 0; channel < 3; ++channel) {
        result.igc[channel] = curve(igc, channels[channel], 257, 4095);
        require(result.igc[channel].back() == 1, "unexpected IGC endpoint");
        result.gc[channel] = curve(gc, channels[channel], 1024, 1023);
    }
    if (enabled(gamut)) result.gamut = cube(gamut, 4095);
    else
        for (unsigned blue = 0; blue < 17; ++blue)
            for (unsigned green = 0; green < 17; ++green)
                for (unsigned red = 0; red < 17; ++red)
                    result.gamut.push_back({gamut_knot(red), gamut_knot(green), gamut_knot(blue)});
    return result;
}
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
    return load_pipeline(igc.get(), gc.get(), gamut.get());
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
    cmsSetProfileVersion(output.get(), 2.4);
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
    /* KWin folds XYZ normalization into this leading LUT16 matrix. */
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
void save_bytes(const std::vector<unsigned char> &data, const char *path) {
    const int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd >= 0, "cannot create new ICC file (existing files are retained)");
    size_t at = 0;
    bool ok = true;
    while (at < data.size()) {
        const ssize_t bytes = write(fd, data.data() + at, data.size() - at);
        if (bytes <= 0) { ok = false; break; }
        at += bytes;
    }
    if (fsync(fd)) ok = false;
    if (close(fd)) ok = false;
    if (!ok) { unlink(path); throw std::runtime_error("ICC write failed"); }
}
void save(cmsHPROFILE profile, const char *path) {
    cmsUInt32Number length = 0;
    require(cmsSaveProfileToMem(profile, nullptr, &length) && length <= 8 * 1024 * 1024, "ICC serialization failed");
    std::vector<unsigned char> data(length);
    require(cmsSaveProfileToMem(profile, data.data(), &length), "ICC serialization failed");
    Icc reopened(cmsOpenProfileFromMem(data.data(), length), cmsCloseProfile);
    require(bool(reopened), "serialized ICC cannot be reopened");
    unsigned char type[4]{};
    require(cmsReadRawTag(reopened.get(), cmsSigBToA1Tag, type, sizeof(type)) == sizeof(type) &&
            std::memcmp(type, "mft2", sizeof(type)) == 0, "ICC requires the original KWin LUT16 path");
    auto pipeline = static_cast<const cmsPipeline *>(cmsReadTag(reopened.get(), cmsSigBToA1Tag));
    require(pipeline && cmsPipelineStageCount(pipeline) == 4, "ICC shader stage count mismatch");
    const cmsStageSignature expected[]{cmsSigMatrixElemType, cmsSigCurveSetElemType,
                                       cmsSigCLutElemType, cmsSigCurveSetElemType};
    auto stage = cmsPipelineGetPtrToFirstStage(pipeline);
    for (auto signature : expected) {
        require(stage && cmsStageType(stage) == signature, "ICC shader stage order mismatch");
        stage = cmsStageNext(stage);
    }
    save_bytes(data, path);
}
double pq_nits(double code) {
    constexpr double m1 = 2610.0 / 16384, m2 = 2523.0 / 32;
    constexpr double c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    const double power = std::pow(std::clamp(code, 0.0, 1.0), 1 / m2);
    return 10000 * std::pow(std::max(power - c1, 0.0) / (c2 - c3 * power), 1 / m1);
}
unsigned crc32(std::string_view data) {
    return o82_hdr_crc32(reinterpret_cast<const unsigned char *>(data.data()), data.size());
}
std::vector<unsigned char> native_hdr(const Profile &factory, unsigned panel, std::string_view input_hash) {
    std::vector<unsigned char> data(O82_HDR_HEADER_SIZE);
    std::copy_n(O82_HDR_MAGIC, 8, data.begin());
    auto word = [&](size_t at, unsigned value) {
        for (unsigned byte = 0; byte < 4; byte++) data.at(at + byte) = value >> (byte * 8);
    };
    auto sample = [&](double value, unsigned maximum) {
        const unsigned quantized = std::lround(std::clamp(value, 0.0, 1.0) * maximum);
        data.push_back(quantized & 255); data.push_back(quantized >> 8);
    };
    require(input_hash.size() == 64 && (panel == 0x36 || panel == 0x42), "invalid native profile identity");
    word(8, O82_HDR_VERSION); word(12, panel); word(16, O82_HDR_FILE_SIZE);
    word(24, O82_HDR_NOMINAL_PEAK_NITS); word(28, O82_HDR_NOMINAL_BLACK_10000);
    for (size_t at = 0; at < 32; at++) {
        unsigned byte;
        const auto [end, error] = std::from_chars(input_hash.data() + at * 2, input_hash.data() + at * 2 + 2, byte, 16);
        require(error == std::errc() && end == input_hash.data() + at * 2 + 2, "invalid native source hash");
        data[32 + at] = byte;
    }
    for (unsigned curve = 0; curve < 2; curve++)
        for (unsigned at = 0; at < O82_HDR_IGC_ENTRIES; at++) {
            const double code = at / 256.0;
            const double linear = curve == 0 ? pq_nits(code) / O82_HDR_NOMINAL_PEAK_NITS : std::pow(code, 2.2);
            for (unsigned channel = 0; channel < 3; channel++) sample(linear, 4095);
        }
    const cmsCIExyY white{0.3127, 0.3290, 1};
    const cmsCIExyYTRIPLE p3{{0.68, 0.32, 1}, {0.265, 0.69, 1}, {0.15, 0.06, 1}};
    const cmsCIExyYTRIPLE bt2020{{0.708, 0.292, 1}, {0.170, 0.797, 1}, {0.131, 0.046, 1}};
    cmsToneCurve *linear = cmsBuildGamma(nullptr, 1);
    require(linear, "linear curve allocation failed");
    cmsToneCurve *curves[]{linear, linear, linear};
    Icc source(cmsCreateRGBProfile(&white, &bt2020, curves), cmsCloseProfile);
    Icc target(cmsCreateRGBProfile(&white, &p3, curves), cmsCloseProfile);
    cmsFreeToneCurve(linear);
    require(source && target, "native gamut profile allocation failed");
    std::unique_ptr<void, decltype(&cmsDeleteTransform)> transform(
        cmsCreateTransform(source.get(), TYPE_RGB_DBL, target.get(), TYPE_RGB_DBL,
                           INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE), cmsDeleteTransform);
    require(bool(transform), "native gamut conversion allocation failed");
    for (unsigned blue = 0; blue < 17; blue++)
        for (unsigned green = 0; green < 17; green++)
            for (unsigned red = 0; red < 17; red++) {
                const Vec input{gamut_knot(red), gamut_knot(green), gamut_knot(blue)};
                Vec result{};
                cmsDoTransform(transform.get(), input.data(), result.data(), 1);
                for (size_t channel = 0; channel < 3; channel++) {
                    const double value = std::clamp(result[channel], 0.0, 1.0);
                    const double encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * std::pow(value, 1 / 2.4) - 0.055;
                    result[channel] = lookup(factory.igc[channel], encoded);
                }
                result = factory.gamut_map(result);
                for (double value : result) sample(value, 4095);
            }
    for (unsigned at = 0; at < O82_HDR_GC_ENTRIES; at++)
        for (size_t channel = 0; channel < 3; channel++) sample(factory.gc[channel][at], 1023);
    require(data.size() == O82_HDR_FILE_SIZE, "native profile length mismatch");
    word(20, crc32(std::string_view(reinterpret_cast<const char *>(data.data() + O82_HDR_HEADER_SIZE), O82_HDR_PAYLOAD_SIZE)));
    require(o82_hdr_valid(data.data(), data.size(), panel), "native profile validation failed");
    return data;
}
std::vector<unsigned char> native_tables(const Profile &factory, unsigned primaries) {
    require(primaries <= O82_COLOR_P3, "unsupported native gamut");
    std::vector<unsigned char> data;
    data.reserve(O82_COLOR_FW_DATA_BYTES);
    auto sample = [&](double value, unsigned maximum) {
        require(std::isfinite(value), "non-finite native table sample");
        const unsigned quantized = std::lround(std::clamp(value, 0.0, 1.0) * maximum);
        data.push_back(quantized & 255); data.push_back(quantized >> 8);
    };
    // The compositor's wire transfer and wire gamut are independent choices.
    for (unsigned pq = 0; pq < 2; pq++)
        for (unsigned at = 0; at < 257; at++) {
            const double code = at / 256.0;
            const double linear = pq ? pq_nits(code) / O82_HDR_NOMINAL_PEAK_NITS : std::pow(code, 2.2);
            for (unsigned channel = 0; channel < 3; channel++) sample(linear, 4095);
        }
    const cmsCIExyY white{0.3127, 0.3290, 1};
    const cmsCIExyYTRIPLE p3{{0.68, 0.32, 1}, {0.265, 0.69, 1}, {0.15, 0.06, 1}};
    const cmsCIExyYTRIPLE srgb{{0.64, 0.33, 1}, {0.30, 0.60, 1}, {0.15, 0.06, 1}};
    const cmsCIExyYTRIPLE bt2020{{0.708, 0.292, 1}, {0.170, 0.797, 1}, {0.131, 0.046, 1}};
    cmsToneCurve *linear = cmsBuildGamma(nullptr, 1);
    require(linear, "native linear curve allocation failed");
    cmsToneCurve *curves[]{linear, linear, linear};
    Icc source(cmsCreateRGBProfile(&white, &bt2020, curves), cmsCloseProfile);
    Icc target(cmsCreateRGBProfile(&white, primaries == O82_COLOR_P3 ? &p3 : &srgb, curves), cmsCloseProfile);
    cmsFreeToneCurve(linear);
    require(source && target, "native input gamut allocation failed");
    std::unique_ptr<void, decltype(&cmsDeleteTransform)> transform(
        cmsCreateTransform(source.get(), TYPE_RGB_DBL, target.get(), TYPE_RGB_DBL,
                           INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE), cmsDeleteTransform);
    require(bool(transform), "native input gamut conversion failed");
    for (unsigned wide = 0; wide < 2; wide++)
        for (unsigned blue = 0; blue < 17; blue++)
            for (unsigned green = 0; green < 17; green++)
                for (unsigned red = 0; red < 17; red++) {
                    const Vec input{gamut_knot(red), gamut_knot(green), gamut_knot(blue)};
                    Vec result = input;
                    if (wide) cmsDoTransform(transform.get(), input.data(), result.data(), 1);
                    for (size_t channel = 0; channel < 3; channel++) {
                        const double value = std::clamp(result[channel], 0.0, 1.0);
                        const double encoded = value <= 0.0031308 ? value * 12.92 :
                            1.055 * std::pow(value, 1 / 2.4) - 0.055;
                        result[channel] = lookup(factory.igc[channel], encoded);
                    }
                    for (double value : factory.gamut_map(result)) sample(value, 4095);
                }
    for (unsigned at = 0; at < 1024; at++)
        for (size_t channel = 0; channel < 3; channel++) sample(factory.gc[channel][at], 1023);
    require(data.size() == O82_COLOR_FW_DATA_BYTES && o82_color_fw_tables(data.data()),
            "invalid native preset tables");
    return data;
}
void put_word(std::vector<unsigned char> &data, size_t at, unsigned value) {
    for (unsigned byte = 0; byte < 4; byte++) data.at(at + byte) = value >> (byte * 8);
}
void put_hash(std::vector<unsigned char> &data, size_t at, std::string_view hash) {
    require(hash.size() == 64, "invalid source identity");
    for (size_t i = 0; i < 32; i++) {
        unsigned byte;
        const auto [end, error] = std::from_chars(hash.data() + i * 2, hash.data() + i * 2 + 2, byte, 16);
        require(error == std::errc() && end == hash.data() + i * 2 + 2, "invalid source hash");
        data.at(at + i) = byte;
    }
}
std::vector<unsigned char> native_hsic(json_object *picture) {
    const double hue = number(field(picture, "hue"));
    require(hue == std::floor(hue) && hue >= std::numeric_limits<std::int32_t>::min() &&
            hue <= std::numeric_limits<std::int32_t>::max(), "invalid HSIC hue");
    const auto scalar = [&](const char *key) {
        const double value = number(field(picture, key));
        require(std::abs(value) <= std::numeric_limits<float>::max(), "invalid HSIC scalar");
        return static_cast<float>(value);
    };
    const o82::HsicInput input{static_cast<std::int32_t>(hue), scalar("sat"), scalar("val"),
                               scalar("cont"), scalar("satThresh")};
    o82::HsicData output;
    require(o82::compile_hsic(input, output) == o82::HsicError::none, "HSIC conversion refused");
    std::vector<unsigned char> data(O82_HSIC_BYTES);
    put_word(data, 0, output.enabled ? O82_HSIC_FLAGS : 0);
    put_word(data, 4, output.hue); put_word(data, 8, output.saturation);
    put_word(data, 12, output.value); put_word(data, 16, output.contrast);
    require(o82_hsic_valid(data.data(), data.size()), "invalid native HSIC payload");
    return data;
}
std::vector<unsigned char> native_memory(json_object *picture) {
    // Primary O82 parser and arithmetic provenance, including its skin edge
    // behavior: manifests/o82-memory-json-source-20261105.json.
    const auto signed_field = [](json_object *object, const char *key) {
        const double value = number(field(object, key));
        require(value == std::floor(value) && value >= std::numeric_limits<std::int32_t>::min() &&
                value <= std::numeric_limits<std::int32_t>::max(), "invalid memory signed field");
        return static_cast<std::int32_t>(value);
    };
    const auto unsigned_field = [](json_object *object, const char *key) {
        const double value = number(field(object, key));
        require(value == std::floor(value) && value >= 0 &&
                value <= std::numeric_limits<std::uint32_t>::max(), "invalid memory unsigned field");
        return static_cast<std::uint32_t>(value);
    };
    const auto scalar = [](json_object *object, const char *key) {
        const double value = number(field(object, key));
        require(std::abs(value) <= std::numeric_limits<float>::max(), "invalid memory scalar");
        return static_cast<float>(value);
    };
    const auto edge_control = [](json_object *object, bool skin_saturation) {
        const auto left = text_field(object, "trapezoidEdgeLeft");
        const auto right = text_field(object, "trapezoidEdgeRight");
        require((left == "SLOPE" || left == "STEP") &&
                (right == "SLOPE" || right == "STEP"), "invalid memory edge");
        // Exact O82 SetConfig checks the right key, then reads the left key
        // again for skin saturation only. Preserve this observed conversion.
        return unsigned(left == "SLOPE") | (unsigned((skin_saturation ? left : right) == "SLOPE") << 1);
    };
    std::vector<unsigned char> data(O82_MEMORY_BYTES);
    put_word(data, 8, O82_MEMORY_VERSION);
    unsigned enabled_mask = 0, protection = 0;
    constexpr const char *regions[]{"MemColSkin", "MemColSky", "MemColFol"};
    for (unsigned i = 0; i < 3; ++i) {
        auto region = field(picture, regions[i]);
        auto hue = field(region, "hue"), sat = field(region, "sat"), val = field(region, "val");
        // Protection is global and is also collected from disabled regions.
        protection |= unsigned(boolean_field(hue, "protect"));
        protection |= unsigned(boolean_field(sat, "protect")) << 1;
        protection |= unsigned(boolean_field(val, "protect")) << 2;
        protection |= unsigned(boolean_field(region, "protectContrast")) << 3;
        protection |= unsigned(boolean_field(region, "protectVsSixZone")) << 4;
        protection |= unsigned(!boolean_field(region, "blendingEnable")) << 5;
        o82::MemoryColorInput input;
        input.hue_adjustment = signed_field(hue, "adj");
        input.hue_extent = std::bit_cast<std::int32_t>(unsigned_field(hue, "mid"));
        input.hue_minimum = signed_field(hue, "min"); input.hue_maximum = signed_field(hue, "max");
        input.saturation_adjustment = scalar(sat, "adj"); input.value_adjustment = scalar(val, "adj");
        input.saturation_extent = unsigned_field(sat, "mid"); input.value_extent = unsigned_field(val, "mid");
        input.saturation_minimum = scalar(sat, "min"); input.saturation_maximum = scalar(sat, "max");
        input.value_minimum = scalar(val, "min"); input.value_maximum = scalar(val, "max");
        input.saturation_hold_control = edge_control(sat, i == 0);
        input.value_hold_control = edge_control(val, false);
        if (!enabled(region)) continue;
        enabled_mask |= 1U << i;
        o82::MemoryColorData output;
        require(o82::compile_memory_color(input, output) == o82::MemoryColorError::none,
                "memory-color conversion refused");
        const std::array<unsigned, 8> words{output.adjust_p0, output.adjust_p1, output.adjust_p2,
            output.blend_gain, unsigned(output.saturation_hold) | (unsigned(output.value_hold) << 2),
            output.hue_region, output.saturation_region, output.value_region};
        for (unsigned j = 0; j < words.size(); ++j)
            put_word(data, O82_MEMORY_HEADER + i * O82_MEMORY_REGION_BYTES + j * 4, words[j]);
    }
    put_word(data, 0, enabled_mask); put_word(data, 4, protection);
    require(o82_memory_valid(data.data(), data.size()), "invalid native memory payload");
    return data;
}
std::vector<unsigned char> native_sixzone(json_object *picture) {
    auto six = field(picture, "SixZone");
    if (!enabled(six)) return {};
    std::array<std::vector<std::uint16_t>, 5> curves;
    constexpr const char *names[]{"hueCurve", "satCurve", "valCurve", "satCurveMid", "satCurveHigh"};
    for (unsigned c = 0; c < curves.size(); ++c) {
        json_object *samples = nullptr;
        if ((!json_object_object_get_ex(six, names[c], &samples) || !samples) && c >= 3) continue;
        require(samples && json_object_is_type(samples, json_type_array) &&
                json_object_array_length(samples) == o82::sixzone_samples, "invalid SixZone curve length");
        for (size_t i = 0; i < o82::sixzone_samples; ++i) {
            const double value = number(json_object_array_get_idx(samples, i));
            require(value >= 0 && value <= 4095 && value == std::floor(value), "invalid SixZone sample");
            curves[c].push_back(static_cast<std::uint16_t>(value));
        }
    }
    const auto percent = [](json_object *object, const char *name) {
        const double value = number(field(object, name));
        require(value >= 0 && value <= 100 && value == std::floor(value), "invalid SixZone threshold");
        return static_cast<int>(value);
    };
    const auto range = [&](json_object *object) -> o82::Range {
        return {percent(object, "min"), percent(object, "max")};
    };
    const auto edges = [](json_object *object) {
        std::array<o82::Edge, 2> result;
        constexpr const char *keys[]{"trapezoidEdgeLeft", "trapezoidEdgeRight"};
        for (unsigned i = 0; i < 2; ++i) {
            const auto edge = text_field(object, keys[i]);
            require(edge == "SLOPE" || edge == "STEP", "invalid SixZone edge");
            result[i] = edge == "STEP" ? o82::Edge::step : o82::Edge::slope;
        }
        return result;
    };
    auto thresholds = field(picture, "SixZoneThresholds");
    auto sat = field(thresholds, "sat"), val = field(thresholds, "val");
    o82::SixZoneInput input;
    input.hue = curves[0]; input.saturation = curves[1]; input.value = curves[2];
    input.saturation_middle = curves[3]; input.saturation_high = curves[4];
    input.thresholds.saturation = range(sat); input.thresholds.value = range(val);
    input.thresholds.saturation_offset = percent(sat, "offset");
    input.thresholds.value_offset = percent(val, "offset");
    input.thresholds.saturation_edges = edges(sat); input.thresholds.value_edges = edges(val);
    unsigned present = 0;
    std::array<o82::Range, 3> bands{};
    constexpr const char *band_names[]{"satLow", "satMid", "satHigh"};
    for (unsigned i = 0; i < 3; ++i) {
        json_object *band = nullptr;
        if (!json_object_object_get_ex(sat, band_names[i], &band) || !band) continue;
        bands[i] = range(band); ++present;
    }
    require(!present || present == 3, "incomplete SixZone saturation bands");
    if (present) input.thresholds.saturation_bands = bands;
    json_object *sv = nullptr;
    if (json_object_object_get_ex(sat, "svEnable", &sv) && sv) {
        require(json_object_is_type(sv, json_type_boolean), "invalid SixZone SV flag");
        input.thresholds.sv_enable = json_object_get_boolean(sv);
    }
    o82::SixZoneData converted;
    require(o82::compile_sixzone(input, converted) == o82::SixZoneError::none,
            "invalid SixZone conversion input");
    std::vector<unsigned char> result(O82_SIXZONE_BYTES);
    put_word(result, 0, converted.flags); put_word(result, 4, converted.threshold);
    put_word(result, 8, converted.adjust_p0); put_word(result, 12, converted.adjust_p1);
    put_word(result, 16, converted.saturation_adjust_p0); put_word(result, 20, converted.saturation_adjust_p1);
    result[24] = converted.saturation_hold; result[25] = converted.value_hold;
    put_word(result, 28, O82_SIXZONE_SAMPLES);
    size_t at = O82_SIXZONE_HEADER;
    const auto sample = [&](unsigned value) {
        result[at++] = value; result[at++] = value >> 8;
    };
    for (unsigned i = 0; i < O82_SIXZONE_SAMPLES; ++i) {
        sample(converted.curve_p0[i]); sample(converted.curve_p1[i] >> 16);
        sample(converted.curve_p2[i] & 0xffff); sample(converted.curve_p2[i] >> 16);
        sample(converted.curve_p1[i] & 0xffff);
    }
    require(at == result.size() && o82_sixzone_valid(result.data(), result.size()),
            "invalid native SixZone payload");
    return result;
}
std::vector<unsigned char> native_presets(json_object *document, const char *panel,
        unsigned panel_id, std::string_view source_hash) {
    auto modes = field(document, panel);
    std::vector<std::string> names;
    json_object_object_foreach(modes, name, mode) {
        require(json_object_is_type(mode, json_type_object), "non-object preset");
        names.emplace_back(name);
    }
    require(!names.empty() && names.size() <= O82_COLOR_FW_MAX_PRESETS, "invalid preset count");
    std::sort(names.begin(), names.end());
    std::vector<unsigned char> data(O82_COLOR_FW_HEADER + names.size() * O82_COLOR_FW_RECORD);
    std::copy_n(O82_COLOR_FW_MEMORY_MAGIC, 8, data.begin());
    put_word(data, 8, O82_COLOR_FW_MEMORY_VERSION); put_word(data, 12, panel_id);
    put_word(data, 24, names.size()); put_word(data, 28, O82_COLOR_FW_RECORD);
    put_hash(data, 32, source_hash);
    put_word(data, 64, O82_HDR_NOMINAL_PEAK_NITS); put_word(data, 68, O82_HDR_NOMINAL_BLACK_10000);
    put_word(data, 72, data.size());
    auto append = [&](const auto &bytes) {
        require(bytes.size() <= O82_COLOR_FW_LIMIT - data.size(), "native preset bundle is too large");
        data.insert(data.end(), bytes.begin(), bytes.end());
    };
    for (size_t index = 0; index < names.size(); index++) {
        const auto &name = names[index];
        const size_t record = O82_COLOR_FW_HEADER + index * O82_COLOR_FW_RECORD;
        require(name.size() < 64, "preset name is too long");
        std::copy(name.begin(), name.end(), data.begin() + record);
        require(o82_color_fw_name(data.data() + record), "invalid preset name");
        auto mode = field(modes, name.c_str());
        json_object_object_foreach(mode, operation, value) {
            (void)value;
            const std::string_view key(operation);
            if (!key.starts_with("PostBlend")) continue;
            require(key == "PostBlendIGC" || key == "PostBlendGC" || key == "PostBlendGamut" ||
                    key == "PostBlendPa" || key == "PostBlendPCC" || key == "PostBlendDE" ||
                    key == "PostBlendDither" || key == "PostBlendPaDither" ||
                    key == "PostBlendGameBlob" || key == "PostBlendHdrBlob", "unrecognized preset operation");
        }
        const auto primaries = text_field(field(mode, "Applicability"), "ColorPrimaries");
        const auto range = text_field(mode, "DynamicRange");
        require((primaries == "P3" || primaries == "sRGB") && (range == "SDR" || range == "HDR") &&
                text_field(field(mode, "Applicability"), "GammaTransfer") == "sRGB", "unsupported preset input contract");
        const unsigned gamut_id = primaries == "P3" ? O82_COLOR_P3 : O82_COLOR_SRGB;
        put_word(data, record + 64, gamut_id); put_word(data, record + 68, range == "HDR");
        put_hash(data, record + 96, sha256(json_object_to_json_string_ext(mode, JSON_C_TO_STRING_PLAIN)));
        auto igc = decode(mode, "PostBlendIGC"), gc = decode(mode, "PostBlendGC");
        auto gamut = decode(mode, "PostBlendGamut"), picture = decode(mode, "PostBlendPa");
        auto factory = load_pipeline(igc.get(), gc.get(), gamut.get());
        unsigned flags = O82_COLOR_OP_IGC | O82_COLOR_OP_GC, blocked = 0;
        if (enabled(gamut.get())) flags |= O82_COLOR_OP_GAMUT;
        const auto dither = field(igc.get(), "ditherEnable");
        require(json_object_is_type(dither, json_type_boolean) ||
                (json_object_is_type(dither, json_type_int) &&
                 (json_object_get_int64(dither) == 0 || json_object_get_int64(dither) == 1)), "invalid IGC dither flag");
        if (json_object_get_boolean(dither)) {
            const double strength = number(field(igc.get(), "ditherStrength"));
            require(strength >= 0 && strength <= 15 && strength == std::floor(strength), "invalid IGC dither strength");
            flags |= O82_COLOR_OP_DITHER;
            put_word(data, record + 128, 1); put_word(data, record + 132, strength);
        }
        for (const char *operation : {"PostBlendPCC", "PostBlendDE", "PostBlendDither", "PostBlendPaDither", "PostBlendGameBlob"}) {
            json_object *unused;
            if (json_object_object_get_ex(mode, operation, &unused)) {
                auto decoded = decode(mode, operation);
                require(!enabled(decoded.get()), "unsupported active preset operation");
            }
        }
        const auto hsic = native_hsic(picture.get());
        if (o82_hdr_u32(hsic.data())) flags |= O82_COLOR_OP_HSIC;
        const auto memory = native_memory(picture.get());
        if (o82_hdr_u32(memory.data()) || o82_hdr_u32(memory.data() + 4)) flags |= O82_COLOR_OP_MEMORY;
        const auto sixzone = native_sixzone(picture.get());
        if (!sixzone.empty()) flags |= O82_COLOR_OP_SIXZONE;
        Json opaque(json_object_new_object(), json_object_put);
        require(bool(opaque) && !json_object_object_add(opaque.get(), "PostBlendPa", json_object_get(picture.get())),
                "preset metadata allocation failed");
        json_object *hdr;
        if (json_object_object_get_ex(mode, "PostBlendHdrBlob", &hdr)) {
            auto decoded = decode(mode, "PostBlendHdrBlob");
            require(!text_field(decoded.get(), "blob").empty(), "empty HDR preset data");
            require(!json_object_object_add(opaque.get(), "PostBlendHdrBlob", json_object_get(decoded.get())),
                    "HDR metadata allocation failed");
            flags |= O82_COLOR_OP_HDR; blocked |= O82_COLOR_BLOCK_HDR;
        }
        require(range != "HDR" || (flags & O82_COLOR_OP_HDR), "HDR preset lacks its HDR operation");
        put_word(data, record + 72, flags); put_word(data, record + 76, blocked);
        if (!blocked) {
            auto tables = native_tables(factory, gamut_id);
            put_word(data, record + 80, data.size()); put_word(data, record + 84, tables.size());
            append(tables);
            if (!sixzone.empty()) {
                put_word(data, record + 136, data.size()); put_word(data, record + 140, sixzone.size());
                append(sixzone);
            }
            put_word(data, record + 144, data.size()); put_word(data, record + 148, hsic.size());
            append(hsic);
            put_word(data, record + 152, data.size()); put_word(data, record + 156, memory.size());
            append(memory);
        }
        const std::string bytes = json_object_to_json_string_ext(opaque.get(), JSON_C_TO_STRING_PLAIN);
        require(!bytes.empty() && bytes.size() <= 2 * 1024 * 1024, "invalid preserved preset data length");
        put_word(data, record + 88, data.size()); put_word(data, record + 92, bytes.size());
        append(bytes);
    }
    put_word(data, 16, data.size());
    put_word(data, 20, o82_hdr_crc32(data.data() + 24, data.size() - 24));
    require(o82_color_fw_valid(data.data(), data.size(), panel_id), "native preset bundle validation failed");
    return data;
}
void preset_self_test(const Profile &identity) {
    auto mode = parse(R"({"Applicability":{"ColorPrimaries":"P3","GammaTransfer":"sRGB"},"DynamicRange":"SDR"})");
    auto encode = [](json_object *value) {
        const std::string raw = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
        const char digits[] = "0123456789abcdef";
        std::string result;
        for (unsigned char byte : raw) { result += digits[byte >> 4]; result += digits[byte & 15]; }
        return json_object_new_string_len(result.data(), result.size());
    };
    for (const char *operation : {"PostBlendIGC", "PostBlendGC"}) {
        const bool input = std::string_view(operation) == "PostBlendIGC";
        auto table = parse(input ? R"({"enable":true,"ditherEnable":false})" :
                                  R"({"enable":true,"bitsRounding":10})");
        for (const char *channel : {"lutR", "lutG", "lutB"}) {
            auto samples = json_object_new_array();
            const unsigned count = input ? 257 : 1024, maximum = input ? 4095 : 1023;
            for (unsigned at = 0; at < count; at++)
                assert(!json_object_array_add(samples, json_object_new_int(std::lround(at * double(maximum) / (count - 1)))));
            assert(!json_object_object_add(table.get(), channel, samples));
        }
        assert(!json_object_object_add(mode.get(), operation, encode(table.get())));
    }
    auto gamut = parse(R"({"enable":false})");
    assert(!json_object_object_add(mode.get(), "PostBlendGamut", encode(gamut.get())));
    auto picture = parse(R"({"hue":0,"sat":0,"satThresh":0,"cont":0,"val":0,"MemColFol":{"enable":false},"MemColSkin":{"enable":false},"MemColSky":{"enable":false},"SixZone":{"enable":false,"hueCurve":[],"satCurve":[],"valCurve":[]}})");
    for (const char *name : {"MemColSkin", "MemColSky", "MemColFol"}) {
        auto memory = parse(R"({"enable":false,"blendingEnable":true,"protectContrast":false,"protectVsSixZone":false,"hue":{"adj":0,"min":0,"max":0,"mid":0,"protect":false},"sat":{"adj":0,"min":0,"max":0,"mid":0,"protect":false,"trapezoidEdgeLeft":"SLOPE","trapezoidEdgeRight":"SLOPE"},"val":{"adj":0,"min":0,"max":0,"mid":0,"protect":false,"trapezoidEdgeLeft":"SLOPE","trapezoidEdgeRight":"SLOPE"}})");
        assert(!json_object_object_add(picture.get(), name, memory.release()));
    }
    assert(!json_object_object_add(mode.get(), "PostBlendPa", encode(picture.get())));
    Json modes(json_object_new_object(), json_object_put), document(json_object_new_object(), json_object_put);
    auto add_mode = [&](const char *name) {
        auto copy = parse(json_object_to_json_string_ext(mode.get(), JSON_C_TO_STRING_PLAIN));
        assert(!json_object_object_add(modes.get(), name, copy.release()));
    };
    add_mode("A_P3");
    assert(!json_object_object_add(field(mode.get(), "Applicability"), "ColorPrimaries", json_object_new_string("sRGB")));
    add_mode("B_sRGB");
    auto clean_mode = parse(json_object_to_json_string_ext(mode.get(), JSON_C_TO_STRING_PLAIN));
    auto six = field(picture.get(), "SixZone");
    auto thresholds = parse(R"({"sat":{"min":0,"max":100,"offset":10,"trapezoidEdgeLeft":"SLOPE","trapezoidEdgeRight":"SLOPE"},"val":{"min":0,"max":100,"offset":10,"trapezoidEdgeLeft":"SLOPE","trapezoidEdgeRight":"SLOPE"}})");
    assert(!json_object_object_add(picture.get(), "SixZoneThresholds", thresholds.release()));
    assert(!json_object_object_add(six, "enable", json_object_new_boolean(true)));
    for (const char *channel : {"hueCurve", "satCurve", "valCurve"}) {
        auto samples = json_object_new_array();
        for (unsigned at = 0; at < 384; at++) assert(!json_object_array_add(samples, json_object_new_int(0)));
        assert(!json_object_object_add(six, channel, samples));
    }
    assert(!json_object_object_add(mode.get(), "PostBlendPa", encode(picture.get())));
    add_mode("C_NeutralSixZone");
    assert(!json_object_array_put_idx(field(six, "satCurve"), 7, json_object_new_int(4095)));
    assert(!json_object_object_add(mode.get(), "PostBlendPa", encode(picture.get())));
    add_mode("D_SixZone");
    assert(!json_object_array_put_idx(field(six, "satCurve"), 7, json_object_new_int(0)));
    assert(!json_object_object_add(field(picture.get(), "MemColSkin"), "enable", json_object_new_boolean(true)));
    assert(!json_object_object_add(mode.get(), "PostBlendPa", encode(picture.get())));
    add_mode("E_Memory");
    assert(!json_object_object_add(field(picture.get(), "MemColSkin"), "enable", json_object_new_boolean(false)));
    assert(!json_object_object_add(picture.get(), "val", json_object_new_int(20)));
    assert(!json_object_object_add(mode.get(), "PostBlendPa", encode(picture.get())));
    add_mode("F_HSIC");
    auto hdr = parse(R"({"blob":"<?xml version=\\\"1.0\\\"?><hdr_lib/>"})");
    assert(!json_object_object_add(mode.get(), "PostBlendHdrBlob", encode(hdr.get())));
    assert(!json_object_object_add(mode.get(), "DynamicRange", json_object_new_string("HDR")));
    add_mode("G_HDR");
    auto dither = decode(clean_mode.get(), "PostBlendIGC");
    assert(!json_object_object_add(dither.get(), "ditherEnable", json_object_new_boolean(true)));
    assert(!json_object_object_add(dither.get(), "ditherStrength", json_object_new_int(3)));
    assert(!json_object_object_add(clean_mode.get(), "PostBlendIGC", encode(dither.get())));
    assert(!json_object_object_add(modes.get(), "H_Dither", clean_mode.release()));
    assert(!json_object_object_add(document.get(), "test_panel", modes.release()));
    constexpr const char *hash = "2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8";
    auto bundle = native_presets(document.get(), "test_panel", 0x42, hash);
    assert(o82_hdr_u32(bundle.data() + 8) == O82_COLOR_FW_MEMORY_VERSION &&
           !std::memcmp(bundle.data(), O82_COLOR_FW_MEMORY_MAGIC, 8));
    assert(o82_color_fw_valid(bundle.data(), bundle.size(), 0x42));
    assert(!o82_color_fw_valid(nullptr, bundle.size(), 0x42));
    assert(!o82_color_fw_valid(bundle.data(), bundle.size() - 1, 0x42));
    assert(!o82_color_fw_valid(bundle.data(), bundle.size(), 0x36));
    assert(!o82_hdr_valid(bundle.data(), bundle.size(), 0x42));
    const unsigned char *igc = nullptr, *gc = nullptr;
    const auto *native = o82_color_fw_data(bundle.data(), 0, 0, 0, &igc, &gc);
    assert(native && igc && gc);
    const auto *gamma22 = igc;
    const auto *wide = o82_color_fw_data(bundle.data(), 0, 1, 0, &igc, &gc);
    assert(igc == gamma22 && wide == native + O82_COLOR_FW_CUBE_BYTES);
    assert(std::memcmp(wide, native, O82_COLOR_FW_CUBE_BYTES));
    const auto *pq_native = o82_color_fw_data(bundle.data(), 0, 0, 1, &igc, &gc);
    assert(pq_native == native && igc == gamma22 + O82_COLOR_FW_CURVE_BYTES);
    assert(std::memcmp(igc, gamma22, O82_COLOR_FW_CURVE_BYTES));
    assert(o82_color_fw_data(bundle.data(), 0, 1, 1, &igc, &gc) == wide);
    const auto *srgb = o82_color_fw_data(bundle.data(), 1, 0, 0, &igc, &gc);
    const auto *srgb_wide = o82_color_fw_data(bundle.data(), 1, 1, 0, &igc, &gc);
    assert(srgb && srgb_wide && std::memcmp(srgb_wide, wide, O82_COLOR_FW_CUBE_BYTES));
    assert(o82_color_fw_data(bundle.data(), 2, 0, 0, &igc, &gc));
    assert(o82_color_fw_data(bundle.data(), 3, 0, 0, &igc, &gc));
    const auto *six_record = o82_color_fw_record(bundle.data(), 3);
    const size_t six_at = o82_hdr_u32(six_record + 136);
    assert(o82_hdr_u32(six_record + 140) == O82_SIXZONE_BYTES);
    assert(o82_sixzone_valid(bundle.data() + six_at, O82_SIXZONE_BYTES));
    // Missing middle/high curves each use the ordinary saturation curve.
    for (unsigned component : {1u, 2u, 3u})
        assert(o82_hdr_u16(bundle.data() + six_at + O82_SIXZONE_HEADER + 7 * 10 + component * 2) == 4095);
    assert(o82_color_fw_data(bundle.data(), 5, 0, 0, &igc, &gc));
    assert(o82_color_fw_data(bundle.data(), 4, 0, 0, &igc, &gc));
    const auto *memory_record = o82_color_fw_record(bundle.data(), 4);
    assert((o82_hdr_u32(memory_record + 72) & O82_COLOR_OP_MEMORY) && !o82_hdr_u32(memory_record + 76));
    assert(o82_hdr_u32(memory_record + 156) == O82_MEMORY_BYTES);
    assert(o82_hdr_u32(bundle.data() + o82_hdr_u32(memory_record + 152)) == 1);
    const auto *retained_igc = igc, *retained_gc = gc;
    for (unsigned index : {6u, 8u, ~0u}) {
        assert(!o82_color_fw_data(bundle.data(), index, 0, 0, &igc, &gc));
        assert(igc == retained_igc && gc == retained_gc);
    }
    assert(!o82_color_fw_data(bundle.data(), 0, 2, 0, &igc, &gc));
    assert(!o82_color_fw_data(bundle.data(), 0, 0, 2, &igc, &gc));
    assert(igc == retained_igc && gc == retained_gc);
    assert(o82_color_fw_data(bundle.data(), 7, 0, 0, &igc, &gc));
    assert(o82_hdr_u32(o82_color_fw_record(bundle.data(), 7) + 128) == 1);
    assert(o82_hdr_u32(o82_color_fw_record(bundle.data(), 7) + 132) == 3);
    const auto snapshot = bundle;
    auto seal = [&] { put_word(bundle, 20, o82_hdr_crc32(bundle.data() + 24, bundle.size() - 24)); };
    auto bad_word = [&](size_t at, unsigned value) {
        bundle = snapshot; put_word(bundle, at, value); seal();
        assert(!o82_color_fw_valid(bundle.data(), bundle.size(), 0x42));
    };
    bad_word(24, 65); bad_word(28, 159); bad_word(64, 1000); bad_word(72, 0);
    bad_word(8, 2);
    bad_word(8, 3);
    bad_word(O82_COLOR_FW_HEADER + 64, 2); bad_word(O82_COLOR_FW_HEADER + 76, O82_COLOR_BLOCK_MEMORY);
    bad_word(O82_COLOR_FW_HEADER + 80, ~0U); bad_word(O82_COLOR_FW_HEADER + 84, 1);
    bad_word(O82_COLOR_FW_HEADER + 88, 0); bad_word(O82_COLOR_FW_HEADER + 92, ~0U);
    bad_word(O82_COLOR_FW_HEADER + 128, 1);
    bad_word(O82_COLOR_FW_HEADER + 7 * O82_COLOR_FW_RECORD + 132, 16);
    bad_word(O82_COLOR_FW_HEADER + 136, six_at);
    bad_word(O82_COLOR_FW_HEADER + 3 * O82_COLOR_FW_RECORD + 136, six_at + 4);
    bad_word(O82_COLOR_FW_HEADER + 3 * O82_COLOR_FW_RECORD + 140, O82_SIXZONE_BYTES - 4);
    bad_word(O82_COLOR_FW_HEADER + 144, 0); bad_word(O82_COLOR_FW_HEADER + 148, 0);
    bad_word(O82_COLOR_FW_HEADER + 152, 1);
    bad_word(six_at + 28, 383); bad_word(six_at + 12, 1); bad_word(six_at, 1);
    const size_t data_start = o82_hdr_u32(snapshot.data() + O82_COLOR_FW_HEADER + 80);
    bundle = snapshot; bundle[data_start] = 1; seal();
    assert(!o82_color_fw_valid(bundle.data(), bundle.size(), 0x42));
    const size_t gc_start = data_start + 2 * O82_COLOR_FW_CURVE_BYTES + 2 * O82_COLOR_FW_CUBE_BYTES;
    bundle = snapshot; bundle[gc_start + 1] = 4; seal();
    assert(!o82_color_fw_valid(bundle.data(), bundle.size(), 0x42));
    bundle = snapshot; bundle[O82_COLOR_FW_HEADER] = '/'; seal();
    assert(!o82_color_fw_valid(bundle.data(), bundle.size(), 0x42));
    bundle = snapshot;
    std::copy_n(bundle.data() + O82_COLOR_FW_HEADER, 64, bundle.data() + O82_COLOR_FW_HEADER + O82_COLOR_FW_RECORD);
    seal(); assert(!o82_color_fw_valid(bundle.data(), bundle.size(), 0x42));
    auto p3_tables = native_tables(identity, O82_COLOR_P3);
    const unsigned node = (2 * 17 + 4) * 17 + 8;
    const double expected = 1.055 * std::pow(gamut_knot(8), 1 / 2.4) - 0.055;
    assert(std::abs(o82_hdr_u16(p3_tables.data() + 2 * O82_COLOR_FW_CURVE_BYTES + node * 6) / 4095.0 - expected) < 0.0003);
    std::cout << "Native v5 preset bundle: distinct gamuts, four wire inputs, active/neutral SixZone and memory, explicit unsupported HDR and parser bounds passed\n";
}
void self_test() {
    Profile identity;
    for (size_t channel = 0; channel < 3; ++channel) {
        for (unsigned at = 0; at < 257; ++at) identity.igc[channel].push_back(at / 256.0);
        for (unsigned at = 0; at < 1024; ++at) identity.gc[channel].push_back(at / 1023.0);
    }
    for (unsigned blue = 0; blue < 17; ++blue)
        for (unsigned green = 0; green < 17; ++green)
            for (unsigned red = 0; red < 17; ++red)
                identity.gamut.push_back({gamut_knot(red), gamut_knot(green), gamut_knot(blue)});
    const std::array<Vec, 11> inputs{{{0,0,0}, {1,1,1}, {0.1,0.2,0.3}, {1,0,0}, {0,1,0}, {0,0,1},
        {0.01,0.01,0.01}, {0.05,0.05,0.05}, {0.18,0.18,0.18}, {0.5,0.5,0.5}, {0.75,0.75,0.75}}};
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
    unsigned char type[4]{};
    assert(cmsReadRawTag(reopened.get(), cmsSigBToA1Tag, type, sizeof(type)) == sizeof(type));
    assert(std::memcmp(type, "mft2", sizeof(type)) == 0);
    auto serialized = static_cast<const cmsPipeline *>(cmsReadTag(reopened.get(), cmsSigBToA1Tag));
    assert(serialized && cmsPipelineStageCount(serialized) == 4);
    const cmsStageSignature expected[]{cmsSigMatrixElemType, cmsSigCurveSetElemType,
                                       cmsSigCLutElemType, cmsSigCurveSetElemType};
    auto stage = cmsPipelineGetPtrToFirstStage(serialized);
    for (auto signature : expected) { assert(stage && cmsStageType(stage) == signature); stage = cmsStageNext(stage); }
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
    assert(crc32("123456789") == 0xcbf43926);
    assert(pq_nits(0) == 0 && std::abs(pq_nits(1) - 10000) < 1e-6);
    assert(std::abs(pq_nits(0.5080784215) - 100) < 0.0001);
    assert(std::abs(pq_nits(0.7518270962) - 1000) < 0.001);
    auto firmware = native_hdr(identity, 0x42, "2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8");
    assert(firmware.size() == O82_HDR_FILE_SIZE);
    const size_t gamut_start = O82_HDR_HEADER_SIZE + O82_HDR_IGC_ENTRIES * 3 * 2 * 2;
    assert(firmware[gamut_start] == 0 && firmware[gamut_start + 1] == 0);
    const size_t white_start = gamut_start + (O82_HDR_GAMUT_ENTRIES - 1) * 3 * 2;
    for (unsigned channel = 0; channel < 3; channel++)
        assert((firmware[white_start + channel * 2] | (firmware[white_start + channel * 2 + 1] << 8)) >= 4094);
    assert(!o82_hdr_valid(nullptr, firmware.size(), 0x42));
    assert(!o82_hdr_valid(firmware.data(), firmware.size() - 1, 0x42));
    assert(!o82_hdr_valid(firmware.data(), firmware.size(), 0x36));
    for (size_t offset : {size_t(8), size_t(20), size_t(24), size_t(32), gamut_start}) {
        firmware[offset] ^= 1;
        assert(!o82_hdr_valid(firmware.data(), firmware.size(), 0x42));
        firmware[offset] ^= 1;
    }
    static_assert(sizeof(unsigned int) == 4 && sizeof(unsigned long long) == 8);
    o82_regdma_descriptor descriptor{};
    for (unsigned ctl = 1; ctl <= 4; ctl++) {
        assert(o82_regdma_make_descriptor(ctl, 0x100000, 8, &descriptor));
        assert(descriptor.offset == ctl * 0x1000 && descriptor.address == 0x100000);
        assert(descriptor.command == 0x01400002);
    }
    assert(o82_regdma_make_descriptor(1, 0xffff0000, 0x3fff * 4, &descriptor));
    assert(descriptor.command == 0x01403fff);
    assert(o82_regdma_make_descriptor(1, 0xffffff00, 256, &descriptor));
    const auto retained = descriptor;
    auto expect_dma_refusal = [&](unsigned ctl, unsigned long long iova, unsigned long bytes) {
        assert(!o82_regdma_make_descriptor(ctl, iova, bytes, &descriptor));
        assert(descriptor.offset == retained.offset && descriptor.address == retained.address &&
               descriptor.command == retained.command);
    };
    expect_dma_refusal(0, 0x100000, 8); expect_dma_refusal(5, 0x100000, 8);
    expect_dma_refusal(~0U, 0x100000, 8); expect_dma_refusal(1, 0, 8);
    expect_dma_refusal(1, 0x100001, 8); expect_dma_refusal(1, 0x100000000ULL, 8);
    expect_dma_refusal(1, ~0ULL, 8); expect_dma_refusal(1, 0xffffff00, 260);
    expect_dma_refusal(1, 0x100000, 0); expect_dma_refusal(1, 0x100000, 4);
    expect_dma_refusal(1, 0x100000, 9); expect_dma_refusal(1, 0x100000, 65536);
    expect_dma_refusal(1, 0x100000, ~0UL);
    assert(!o82_regdma_make_descriptor(1, 0x100000, 8, nullptr));
    preset_self_test(identity);
    std::cout << "Decoder, gamut, KWin LUT16 stage contract, dark/gray XYZ/P3 roundtrip, PQ, firmware and Cliffs DMA descriptor bounds passed\n";
}
}
int main(int argc, char **argv) {
    try {
        if (argc == 2 && std::string_view(argv[1]) == "--self-test") { self_test(); return 0; }
        if (argc == 3 && std::string_view(argv[1]) == "--prepare-kernel") {
            const std::string release = argv[2];
            utsname running{};
            require(!uname(&running), "cannot identify running kernel");
            o82_stock::release_name(release, running.release);
            const unsigned panel = o82_stock::board_panel();
            auto modules = directory(fs::path("/usr/lib/modules") / release);
            const auto composition_bytes = file(fs::path("/usr/share/senemos/uke") / release / "source-composition.json");
            auto composition = parse({reinterpret_cast<const char *>(composition_bytes.data()), composition_bytes.size()});
            o82_stock::candidate(composition.get(), release, running.release);
            const auto raw = o82_stock::acquire(panel);
            auto document = parse({reinterpret_cast<const char *>(raw.data()), raw.size()});
            const auto name = o82_stock::panel_name(panel);
            const auto bundle = native_presets(document.get(), name.c_str(), panel, o82_stock::input_hash(panel));
            o82_stock::publish(fs::path("/usr/lib/firmware") / release / "qcom/sm7675/uke" /
                o82_stock::filename(panel), bundle, panel);
            std::cout << "Prepared private fitted-panel v5 data for " << release <<
                "; stock stayed read-only and initial selection is unchanged\n";
            return 0;
        }
        const bool native = argc == 4 && std::string_view(argv[1]) == "--native-hdr";
        const bool presets = argc == 4 && std::string_view(argv[1]) == "--native-presets";
        require(native || presets || (argc == 3 && !std::string_view(argv[1]).starts_with("--")),
            "usage: uke-o82-color-profile --prepare-kernel RELEASE | [--native-presets|--native-hdr] OEM_QDCM_JSON NEW_PRIVATE_OUTPUT");
        const auto data = read_file(argv[native || presets ? 2 : 1]);
        const auto hash = sha256(data);
        const char *panel = nullptr;
        if (hash == "bd88eb94134e5f62c05eebaa0a9e4b5267968363f72f440018b98a15d1bd9122") panel = "xiaomi_o82_36_02_0a_vid_mode_dualdsi_dsc_panel";
        if (hash == "2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8") panel = "xiaomi_o82_42_02_0b_vid_mode_dualdsi_dsc_panel";
        require(panel, "unreviewed OEM profile hash");
        auto document = parse(data);
        auto factory = load(document.get(), panel);
        if (presets) {
            auto bundle = native_presets(document.get(), panel, std::string_view(panel).find("42_02_0b") != std::string_view::npos ? 0x42 : 0x36, hash);
            const unsigned count = o82_hdr_u32(bundle.data() + 24);
            unsigned compiled = 0;
            for (unsigned at = 0; at < count; at++)
                compiled += !o82_hdr_u32(o82_color_fw_record(bundle.data(), at) + 76);
            save_bytes(bundle, argv[3]);
            std::cout << "Generated private bundle: " << count << " presets, " << compiled <<
                " compiled; remaining operations preserved with explicit refusal. Native driver/optical acceptance remains separate\n";
            return 0;
        }
        if (native) {
            save_bytes(native_hdr(factory, std::string_view(panel).find("42_02_0b") != std::string_view::npos ? 0x42 : 0x36, hash), argv[3]);
            std::cout << "Generated private O82 HDR10/PQ and BT.2020 color data; driver and optical acceptance remain separate\n";
            return 0;
        }
        auto profile = make_icc(factory);
        save(profile.get(), argv[2]);
        std::cout << "Generated private " << panel << " P3 ICC mapping; optical calibration and HDR10/EDR acceptance remain unmeasured\n";
    } catch (const std::exception &error) {
        std::cerr << "O82 profile: " << error.what() << '\n';
        return 1;
    }
}
