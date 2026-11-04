// SPDX-License-Identifier: MIT
// COPR only: actual admission/publication and synthetic v5 data, no stock I/O.
#define UKE_LOCAL_FW_TEST
#include "o82-color-profile.cpp"
#include <sys/resource.h>

namespace {
unsigned stock_checks = 0;
void check_stock(bool value) {
    ++stock_checks;
    if (!value) throw std::runtime_error("stock profile check " + std::to_string(stock_checks) + " failed");
}
template<class Call> void refusal(Call call) {
    bool refused = false;
    try { call(); } catch (const std::exception &) { refused = true; }
    check_stock(refused);
}
Json composition() {
    return parse(R"({"kernel_release":"7.3.1-12102-unstable","package_family":"senemos-uke-linux-kernel-mainline-unstable","o82_memory_layer":1,"o82_private_color_bundle_version":5,"o82_lutbus_max_bytes":41488,"o82_memory_software_support":true,"o82_memory_protection_software_support":true,"o82_explicit_neutral_memory":true,"o82_color_dma_enabled":false,"native_hdr_advertised":false,"o82_color_initial_preset":""})");
}
json_object *encoded(json_object *object) {
    const std::string raw = json_object_to_json_string_ext(object, JSON_C_TO_STRING_PLAIN);
    std::string hex;
    for (unsigned char c : raw) { hex += "0123456789abcdef"[c >> 4]; hex += "0123456789abcdef"[c & 15]; }
    return json_object_new_string_len(hex.data(), hex.size());
}
Bytes synthetic_bundle(unsigned panel, const char *preset = "standard_P3") {
    auto mode = parse(R"({"Applicability":{"ColorPrimaries":"P3","GammaTransfer":"sRGB"},"DynamicRange":"SDR"})");
    for (const char *operation : {"PostBlendIGC", "PostBlendGC"}) {
        const bool input = std::string_view(operation) == "PostBlendIGC";
        auto table = parse(input ? R"({"enable":true,"ditherEnable":false})" : R"({"enable":true,"bitsRounding":10})");
        for (const char *channel : {"lutR", "lutG", "lutB"}) {
            auto samples = json_object_new_array();
            const unsigned count = input ? 257 : 1024, maximum = input ? 4095 : 1023;
            for (unsigned i = 0; i < count; i++)
                check_stock(!json_object_array_add(samples, json_object_new_int(std::lround(i * double(maximum) / (count - 1)))));
            check_stock(!json_object_object_add(table.get(), channel, samples));
        }
        check_stock(!json_object_object_add(mode.get(), operation, encoded(table.get())));
    }
    auto gamut = parse(R"({"enable":false})");
    check_stock(!json_object_object_add(mode.get(), "PostBlendGamut", encoded(gamut.get())));
    auto picture = parse(R"({"hue":0,"sat":0,"satThresh":0,"cont":0,"val":0,"SixZone":{"enable":false}})");
    for (const char *region : {"MemColSkin", "MemColSky", "MemColFol"}) {
        auto neutral = parse(R"({"enable":false,"blendingEnable":true,"protectContrast":false,"protectVsSixZone":false,"hue":{"adj":0,"min":0,"max":0,"mid":0,"protect":false},"sat":{"adj":0,"min":0,"max":0,"mid":0,"protect":false,"trapezoidEdgeLeft":"STEP","trapezoidEdgeRight":"STEP"},"val":{"adj":0,"min":0,"max":0,"mid":0,"protect":false,"trapezoidEdgeLeft":"STEP","trapezoidEdgeRight":"STEP"}})");
        check_stock(!json_object_object_add(picture.get(), region, neutral.release()));
    }
    check_stock(!json_object_object_add(mode.get(), "PostBlendPa", encoded(picture.get())));
    Json modes(json_object_new_object(), json_object_put), document(json_object_new_object(), json_object_put);
    check_stock(!json_object_object_add(modes.get(), preset, mode.release()));
    check_stock(!json_object_object_add(document.get(), "synthetic", modes.release()));
    return native_presets(document.get(), "synthetic", panel, o82_stock::input_hash(panel));
}
void admission() {
    const std::string release = "7.3.1-12102-unstable", running = "7.3.1-11003-unstable";
    auto good = composition();
    o82_stock::candidate(good.get(), release, running);
    for (const char *key : {"kernel_release", "package_family", "o82_memory_layer", "o82_private_color_bundle_version",
            "o82_lutbus_max_bytes", "o82_memory_software_support", "o82_memory_protection_software_support",
            "o82_explicit_neutral_memory", "o82_color_dma_enabled", "native_hdr_advertised", "o82_color_initial_preset"}) {
        for (unsigned mutation = 0; mutation < 3; mutation++) {
            auto bad = composition();
            if (!mutation) json_object_object_del(bad.get(), key);
            else check_stock(!json_object_object_add(bad.get(), key,
                mutation == 1 ? json_object_new_string("false") : json_object_new_int(0)));
            refusal([&] { o82_stock::candidate(bad.get(), release, running); });
        }
    }
    for (const char *key : {"source_check_view_only", "native_hdr_advertised", "o82_color_dma_enabled"}) {
        auto bad = composition();
        check_stock(!json_object_object_add(bad.get(), key, json_object_new_boolean(true)));
        refusal([&] { o82_stock::candidate(bad.get(), release, running); });
    }
    check_stock(!json_object_object_add(good.get(), "source_check_view_only", json_object_new_boolean(false)));
    o82_stock::candidate(good.get(), release, running);
    for (const auto &bad : {release, std::string("7.3.1-12102"), std::string("7.3.1-0-unstable"),
         std::string("7.3.1-01-unstable"), std::string("7.3.1-1/2-unstable"), std::string("7.3.1-1x-unstable"),
         std::string("7.3.1--unstable"), std::string("../12102"), std::string("7.3.1-4294967296-unstable")})
        refusal([&] { o82_stock::release_name(bad, release); });
    o82_stock::release_name("7.3.1-1-unstable", running);
    refusal([&] { (void)o82_stock::filename(0); });
    check_stock(o82_stock::filename(0x36) != o82_stock::filename(0x42));
    for (unsigned panel : {0x36u, 0x42u}) {
        const auto name = o82_stock::panel_name(panel);
        check_stock(name.find(panel == 0x36 ? "36_02_0a" : "42_02_0b") != std::string::npos);
        check_stock(o82_stock::input_hash(panel).size() == 64);
    }
}
void publication(const fs::path &scratch) {
    for (unsigned panel : {0x36u, 0x42u}) {
        const auto bytes = synthetic_bundle(panel), other = synthetic_bundle(panel, "alternate");
        const auto root = scratch / std::to_string(panel);
        const auto target = root / o82_stock::filename(panel);
        o82_stock::publish(target, bytes, panel);
        struct stat st{};
        check_stock(!stat(target.c_str(), &st) && st.st_nlink == 1 && (st.st_mode & 07777) == 0600);
        const auto inode = st.st_ino;
        o82_stock::publish(target, bytes, panel);
        check_stock(!stat(target.c_str(), &st) && st.st_ino == inode && file(target) == bytes);
        refusal([&] { o82_stock::publish(target, other, panel); });
        check_stock(file(target) == bytes);
        check_stock(!chmod(target.c_str(), 0644));
        refusal([&] { o82_stock::publish(target, bytes, panel); });
        check_stock(!chmod(target.c_str(), 0600));
        const auto alias = root / "hardlink";
        check_stock(!link(target.c_str(), alias.c_str()));
        refusal([&] { o82_stock::publish(target, bytes, panel); });
        check_stock(!unlink(alias.c_str()));
        const auto unsafe = root / "symlink";
        check_stock(!symlink(root.c_str(), unsafe.c_str()));
        refusal([&] { o82_stock::publish(unsafe / o82_stock::filename(panel), bytes, panel); });
        check_stock(!unlink(unsafe.c_str()));
        check_stock(!unlink(target.c_str()) && !symlink("missing", target.c_str()));
        refusal([&] { o82_stock::publish(target, bytes, panel); });
        check_stock(fs::is_symlink(target) && !fs::exists(root / "missing"));
        check_stock(!unlink(target.c_str()));
        auto corrupt = bytes;
        corrupt.back() ^= 1;
        refusal([&] { o82_stock::publish(target, corrupt, panel); });
        refusal([&] { o82_stock::publish(target, bytes, panel == 0x36 ? 0x42 : 0x36); });
        check_stock(fs::is_empty(root));
        const auto child = fork();
        check_stock(child >= 0);
        if (!child) {
            signal(SIGXFSZ, SIG_IGN);
            rlimit limit{1, 1};
            if (setrlimit(RLIMIT_FSIZE, &limit)) _exit(2);
            try { o82_stock::publish(target, bytes, panel); } catch (const std::exception &) { _exit(0); }
            _exit(3);
        }
        int status = 0;
        check_stock(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        check_stock(fs::is_empty(root));
        std::vector<pid_t> children;
        for (unsigned i = 0; i < 4; i++) {
            const auto pid = fork();
            check_stock(pid >= 0);
            if (!pid) {
                try { o82_stock::publish(target, bytes, panel); _exit(0); } catch (const std::exception &) { _exit(4); }
            }
            children.push_back(pid);
        }
        for (auto pid : children)
            check_stock(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        check_stock(file(target) == bytes && std::distance(fs::directory_iterator(root), fs::directory_iterator{}) == 1);
    }
}
} // namespace
extern "C" int __wrap_main() {
    try {
        admission();
        char pattern[] = "/tmp/o82-stock-contract-XXXXXX";
        const char *created = mkdtemp(pattern);
        check_stock(created);
        const fs::path scratch = created;
        struct Cleanup { fs::path path; ~Cleanup() { fs::remove_all(path); } } cleanup{scratch};
        publication(scratch);
        std::cout << "Actual private-v5 admission/publication: " << stock_checks <<
            " checks, both suppliers, exact idempotence, differing/public/symlink/hardlink refusal, anonymous failed-write cleanup and concurrent no-replace publication passed; synthetic files only\n";
        return 0;
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
