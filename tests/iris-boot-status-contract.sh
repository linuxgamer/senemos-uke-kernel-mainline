#!/usr/bin/env bash
# Host-only fixture of the real boot function; never starts firmware.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <utility>
#include <vector>
using u32 = std::uint32_t;
using u8 = std::uint8_t;
#define BIT(n) (u32{1} << (n))
#include "iris_vpu_register_defines.h"
constexpr u32 CTRL_INIT = 0xa0048, CTRL_STATUS = 0xa004c;
constexpr u32 CPU_CS_SCIACMDARG3 = 0xa0058;
constexpr u32 CTRL_ERROR_STATUS__M = 0xfe;
struct iris_core { u8 *reg_base; void *dev; };
static u8 registers[0xf0000];
static unsigned reads, sleeps, setup_calls, errors, ready_after;
static u32 status;
static int setup_error;
static std::vector<std::pair<u32, u32>> writes;
static int iris_vpu_setup_ucregion_memory_map(iris_core *) { ++setup_calls; return setup_error; }
static u32 readl(const void *address) {
    assert(address == registers + CTRL_STATUS);
    ++reads;
    return reads <= ready_after ? 0x100 : status;
}
static void writel(u32 value, void *address) {
    const auto offset = static_cast<u8 *>(address) - registers;
    assert(offset >= 0 && offset < 0xf0000);
    writes.emplace_back(static_cast<u32>(offset), value);
}
static void usleep_range(unsigned low, unsigned high) {
    assert(low == 50 && high == 100); ++sleeps;
}
#define dev_err(...) (++errors)
CPP
awk '/^int iris_vpu_boot_firmware\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_vpu_common.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static int run(u32 result, unsigned pending = 0) {
    status = result; ready_after = pending;
    reads = sleeps = setup_calls = errors = 0; writes.clear();
    iris_core core{registers, nullptr};
    const int ret = iris_vpu_boot_firmware(&core);
    assert(setup_calls == 1 && reads <= 1000 && sleeps <= 1000);
    assert(writes.size() >= 2);
    assert((writes[0] == std::pair<u32, u32>{CTRL_INIT, 1}));
    assert((writes[1] == std::pair<u32, u32>{CPU_CS_SCIACMDARG3, 1}));
    if (ret) assert(writes.size() == 2 && errors == 1);
    else {
        assert(writes.size() == 4 && errors == 0);
        assert((writes[2] == std::pair<u32, u32>{CPU_CS_H2XSOFTINTEN, 1}));
        assert((writes[3] == std::pair<u32, u32>{CPU_CS_X2RPMH, 0}));
    }
    return ret;
}
int main() {
    iris_core core{registers, nullptr};
    setup_error = -EINVAL;
    assert(iris_vpu_boot_firmware(&core) == -EINVAL && writes.empty() && reads == 0);
    setup_error = 0;
    assert(run(1) == 0 && reads == 1);
    assert(run(1, 5) == 0 && reads == 6);
    assert(run(1, 999) == 0 && reads == 1000);
    assert(run(0) == -ETIME && reads == 1000);
    assert(run(0x100) == -ETIME && reads == 1000);
    for (u32 bit = 1; bit <= 7; ++bit) {
        assert(run(BIT(bit)) == -EIO && reads == 1);
        assert(run(BIT(bit) | 1) == -EIO && reads == 1);
    }
    assert(run(0x0e, 4) == -EIO && reads == 5);
}
CPP
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror -I "$iris" \
    "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual Iris boot status: ready, pending, timeout and all error bits: passed\n'
