// SPDX-License-Identifier: MIT
// Private local preparation; provenance: o82-stock-profile-source-20261105.json.
#pragma once
#include <charconv>
#include <json-c/json.h>
#include "o82-color-firmware.h"
// Preserve the existing project's compact helper source without weakening
// diagnostics on this implementation or the color converter.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmisleading-indentation"
#include "stock-profile/local.hpp"
#pragma GCC diagnostic pop

namespace o82_stock {
inline std::string panel_name(unsigned panel) {
    need(panel == 0x36 || panel == 0x42, "Unsupported O82 supplier");
    return std::string("xiaomi_o82_") + (panel == 0x42 ? "42_02_0b" : "36_02_0a") +
        "_vid_mode_dualdsi_dsc_panel";
}
inline std::string input_hash(unsigned panel) {
    (void)panel_name(panel);
    return panel == 0x42 ? "2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8" :
        "bd88eb94134e5f62c05eebaa0a9e4b5267968363f72f440018b98a15d1bd9122";
}
inline std::string filename(unsigned panel) {
    (void)panel_name(panel);
    return std::string("o82-") + (panel == 0x42 ? "42" : "36") + "-color-v5.bin";
}
inline void release_name(const std::string &release, const std::string &running) {
    need(token(release) && release.starts_with("7.3.1-") && release.ends_with("-unstable") &&
         release != running && release.size() > 15, "A non-running unstable kernel release is required");
    const auto digits = std::string_view(release).substr(6, release.size() - 15);
    unsigned revision = 0;
    const auto result = std::from_chars(digits.data(), digits.data() + digits.size(), revision);
    need(result.ec == std::errc() && result.ptr == digits.data() + digits.size() && revision &&
         digits.front() != '0', "Invalid unstable kernel revision");
}
inline json_object *member(json_object *object, const char *key) {
    json_object *value = nullptr;
    need(object && json_object_is_type(object, json_type_object) &&
         json_object_object_get_ex(object, key, &value), "Missing candidate composition field");
    return value;
}
inline bool flag(json_object *object, const char *key) {
    auto value = member(object, key);
    need(json_object_is_type(value, json_type_boolean), "Candidate field is not boolean");
    return json_object_get_boolean(value);
}
inline void candidate(json_object *object, const std::string &release, const std::string &running) {
    release_name(release, running);
    auto text_is = [&](const char *key, const std::string &expected) {
        auto value = member(object, key);
        return json_object_is_type(value, json_type_string) &&
            size_t(json_object_get_string_len(value)) == expected.size() &&
            std::string_view(json_object_get_string(value), expected.size()) == expected;
    };
    auto integer_is = [&](const char *key, int64_t expected) {
        auto value = member(object, key);
        return json_object_is_type(value, json_type_int) && json_object_get_int64(value) == expected;
    };
    need(text_is("kernel_release", release) &&
         text_is("package_family", "senemos-uke-linux-kernel-mainline-unstable") &&
         text_is("o82_color_initial_preset", "") && integer_is("o82_memory_layer", 1) &&
         integer_is("o82_private_color_bundle_version", 5) && integer_is("o82_lutbus_max_bytes", 41488) &&
         flag(object, "o82_memory_software_support") && flag(object, "o82_memory_protection_software_support") &&
         flag(object, "o82_explicit_neutral_memory") && !flag(object, "o82_color_dma_enabled") &&
         !flag(object, "native_hdr_advertised"), "Candidate lacks the qualified inactive memory/v5 contract");
    json_object *view = nullptr;
    if (json_object_object_get_ex(object, "source_check_view_only", &view))
        need(json_object_is_type(view, json_type_boolean) && !json_object_get_boolean(view),
             "Source-check views cannot receive firmware");
}
inline Bytes sysfile(const fs::path &path, size_t maximum = 1024) {
    Fd fd(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK));
    Bytes bytes;
    std::array<unsigned char, 256> buffer{};
    for (;;) {
        const auto size = read(fd.value, buffer.data(), buffer.size());
        if (size < 0 && errno == EINTR) continue;
        need(size >= 0 && bytes.size() + size_t(size) <= maximum, "Invalid bounded sysfs field");
        if (!size) return bytes;
        bytes.insert(bytes.end(), buffer.begin(), buffer.begin() + size);
    }
}
inline bool compatible(const Bytes &bytes, const std::string &name) {
    size_t at = 0;
    while (at < bytes.size()) {
        const auto end = std::find(bytes.begin() + at, bytes.end(), 0);
        need(end != bytes.end(), "Unterminated DT compatible field");
        const std::string token(bytes.begin() + at, end);
        if (token == name) return true;
        at = size_t(end - bytes.begin()) + 1;
    }
    return false;
}
inline unsigned board_panel() {
    need(geteuid() == 0, "Administrator authentication is required for local profile preparation");
    const auto board = sysfile("/sys/firmware/devicetree/base/compatible");
    need(compatible(board, "xiaomi,uke") && compatible(board, "qcom,sm7675"), "Exact Uke/SM7675 identity required");
    const auto panel = sysfile("/sys/firmware/devicetree/base/soc/display-subsystem@ae00000/dsi@ae94000/panel@0/compatible");
    const bool a = compatible(panel, "xiaomi,o82-36-02-0a"), b = compatible(panel, "xiaomi,o82-42-02-0b");
    need(a != b, "One exact fitted O82 supplier is required");
    return b ? 0x42 : 0x36;
}
inline Bytes acquire(unsigned panel) {
    const auto path = fs::canonical("/dev/disk/by-partlabel/super");
    need(path.parent_path() == "/dev", "Unexpected stock super symlink target");
    Fd source(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK));
    struct stat st{}, root{};
    uint64_t size = 0;
    need(!fstat(source.value, &st) && S_ISBLK(st.st_mode) &&
         !ioctl(source.value, BLKGETSIZE64, &size) && size && !stat("/", &root), "Invalid stock super descriptor");
    const auto sys = fs::canonical("/sys/dev/block/" + std::to_string(major(st.st_rdev)) + ":" + std::to_string(minor(st.st_rdev)));
    const auto root_sys = fs::canonical("/sys/dev/block/" + std::to_string(major(root.st_dev)) + ":" + std::to_string(minor(root.st_dev)));
    const auto controller = fs::canonical("/sys/bus/platform/devices/1d84000.ufshc");
    need(fs::exists(sys / "partition") && below(sys, controller) &&
         fs::canonical(controller / "driver") == "/sys/bus/platform/drivers/ufshcd-qcom" &&
         sys.parent_path() == root_sys.parent_path(), "Stock source is outside the observed Uke root disk");
    const auto parts = uke_video::partitions(source.value, size);
    const auto odm = parts.find("odm_a");
    need(odm != parts.end(), "Stock ODM extent is absent");
    trusted("/usr/bin/debugfs");
    auto [loop, device] = uke_video::readonly_loop(source.value, odm->second);
    const auto data = uke_video::capture({"/usr/bin/debugfs", "-R",
        "cat /etc/display/qdcm_calib_data_" + panel_name(panel) + ".json", device}, 32 * 1024 * 1024);
    need(digest(data) == input_hash(panel), "Unreviewed stock O82 profile; nothing was published");
    return data;
}
inline void publish(const fs::path &destination, const Bytes &bytes, unsigned panel) {
    need(destination.filename() == filename(panel) &&
         o82_color_fw_valid(bytes.data(), bytes.size(), panel) && o82_hdr_u32(bytes.data() + 8) == 5,
         "Invalid supplier-specific private v5 bundle");
    auto parent = directory(destination.parent_path(), true);
    auto existing = [&] {
        Fd fd(openat(parent.value, destination.filename().c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
        trusted_fd(fd.value);
        struct stat st{};
        need(!fstat(fd.value, &st) && (st.st_mode & 07777) == 0600 &&
             read_fd(fd.value, st.st_size) == bytes, "Existing private profile differs or has unsafe permissions");
    };
    struct stat present{};
    if (!fstatat(parent.value, destination.filename().c_str(), &present, AT_SYMLINK_NOFOLLOW)) {
        existing();
        return;
    }
    need(errno == ENOENT, "Cannot inspect private destination");
    Fd staged(openat(parent.value, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600));
    size_t done = 0;
    while (done < bytes.size()) {
        const auto count = write(staged.value, bytes.data() + done, bytes.size() - done);
        if (count < 0 && errno == EINTR) continue;
        need(count > 0, "Cannot stage private profile");
        done += size_t(count);
    }
    need(!fchmod(staged.value, 0600) && !fsync(staged.value) && read_fd(staged.value, bytes.size()) == bytes,
         "Private profile staging readback differs");
    const auto descriptor = "/proc/self/fd/" + std::to_string(staged.value);
    if (linkat(AT_FDCWD, descriptor.c_str(), parent.value, destination.filename().c_str(), AT_SYMLINK_FOLLOW)) {
        need(errno == EEXIST, "Cannot publish private profile without replacement");
        existing();
    }
    need(!fsync(parent.value), "Cannot sync private profile directory");
    existing();
}
} // namespace o82_stock
