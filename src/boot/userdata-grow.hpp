// SPDX-License-Identifier: MIT
#pragma once
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace uke::userdata {
using Header = std::array<unsigned char, 144>;
inline std::uint64_t little(const Header &h, unsigned offset, unsigned size) {
    std::uint64_t value = 0;
    for (unsigned i = 0; i < size; ++i) value |= std::uint64_t(h.at(offset + i)) << (8 * i);
    return value;
}
inline std::uint64_t filesystem_bytes(const Header &first, const Header &second, std::uint64_t device_bytes) {
    // The on-disk fields follow upstream include/linux/f2fs_fs.h.
    if (first != second || little(first, 0, 4) != 0xf2f52010 ||
        little(first, 16, 4) != 12 || little(first, 20, 4) != 9 ||
        !little(first, 24, 4) || little(first, 24, 4) > 1024 ||
        !little(first, 28, 4) || little(first, 28, 4) > 1024 || device_bytes % 4096)
        throw std::runtime_error("invalid or inconsistent F2FS geometry");
    const auto blocks = little(first, 36, 8);
    if (blocks < 32768 || blocks > device_bytes / 4096)
        throw std::runtime_error("filesystem exceeds the partition or has invalid size");
    bool uuid = false;
    for (unsigned i = 108; i < 124; ++i) uuid |= first[i] != 0;
    constexpr std::string_view label = "UKE_LINUX";
    for (unsigned i = 0; i < label.size(); ++i)
        if (first[124 + 2 * i] != label[i] || first[125 + 2 * i])
            throw std::runtime_error("userdata does not have the provisioned label");
    if (!uuid || first[142] || first[143]) throw std::runtime_error("invalid filesystem identity");
    return blocks * 4096;
}
inline bool needs_growth(const Header &first, const Header &second, std::uint64_t device_bytes) {
    const auto bytes = filesystem_bytes(first, second, device_bytes);
    return device_bytes - bytes >= 4096ULL * 512 * little(first, 24, 4);
}
}
