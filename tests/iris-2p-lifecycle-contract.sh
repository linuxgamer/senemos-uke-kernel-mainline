#!/usr/bin/env bash
# Coordinator-run host fault fixture; no module, firmware or device access.
set -Eeuo pipefail
iris=${1:?Pass the prepared drivers/media/platform/qcom/iris directory}
here=$(cd -- "$(dirname -- "$0")" && pwd)
test -f "$iris/iris_vpu33_2p.h"
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <array>
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <utility>
#include <vector>
#include <linux/io.h>
#define BIT(n) (u32{1} << (n))
#include "iris_vpu_register_defines.h"
#include "iris_vpu33_2p.h"
static std::array<u32, 0xf0000 / 4> registers;
static std::vector<std::pair<u32, u32>> writes;
static unsigned sleeps, reads, fault;
static u8 *base() { return reinterpret_cast<u8 *>(registers.data()); }
static u32 offset(const volatile void *address) {
    const auto value = reinterpret_cast<std::uintptr_t>(address) -
                       reinterpret_cast<std::uintptr_t>(base());
    assert(value % 4 == 0 && value < 0xf0000);
    return static_cast<u32>(value);
}
u32 readl(const volatile void *address) {
    const auto reg = offset(address);
    ++reads;
    if (reg == 0x70 || reg == 0x74)
        return fault == (reg == 0x70 ? 1 : 2) ? 0 : BIT(22);
    if (reg == 0xe0004)
        return fault == 3 ? BIT(1) | BIT(2) : BIT(0);
    const u32 sense[] = {0x13300, 0x13304, 0x1330c, 0x13310};
    const u32 masks[] = {0x8000, 0x800, 0x800000, 0x2000};
    for (unsigned i = 0; i < 4; ++i)
        if (reg == sense[i] && fault == i + 4)
            return masks[i];
    return registers[reg / 4];
}
void writel(u32 value, volatile void *address) {
    const auto reg = offset(address);
    writes.emplace_back(reg, value);
    registers[reg / 4] = value;
}
static void usleep_range(unsigned minimum, unsigned maximum) {
    assert(minimum == 10 && maximum == 20);
    ++sleeps;
}
#define readl_poll_timeout(address, value, condition, delay, timeout) \
    ([&]() { \
        for (unsigned poll = 0; poll <= (timeout) / (delay); ++poll) { \
            (value) = readl(address); \
            if (condition) return 0; \
        } \
        return -ETIMEDOUT; \
    }())
struct iris_core { u8 *reg_base; };
CPP
awk '/^int iris_vpu33_2p_quiesce\(/ { emit=1 } emit { print } emit && /^}/ { exit }' \
    "$iris/iris_vpu3x.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static void clear(unsigned selected_fault = 0) {
    registers.fill(0); writes.clear(); sleeps = reads = 0; fault = selected_fault;
    registers[0xe0000 / 4] = 0x80;
    registers[0x87b8 / 4] = 0x20;
}
static std::vector<u32> bridge_writes() {
    std::vector<u32> values;
    for (const auto &[reg, value] : writes)
        if (reg == 0xa0160) values.push_back(value);
    return values;
}
int main() {
    clear();
    registers[0xb0088 / 4] = 0xb5;
    iris_vpu33_2p_write_presets(base());
    const std::vector<std::pair<u32, u32>> expected = {
        {0xb0088, 0xa4}, {0x10830, 0x33332222}, {0x10834, 0x44444444},
        {0x10838, 0x1022}, {0xa013c, 0x99},
        {0x13518, 1}, {0x13508, 3}, {0x13240, 1}};
    assert(writes == expected);
    // No four-pipe 0x1a000 logger register may be touched.
    for (const auto &[reg, value] : writes) { (void)value; assert(reg < 0x1a000 || reg >= 0xa0000); }
    iris_core core{base()};
    clear();
    assert(iris_vpu33_2p_quiesce(&core) == 0);
    assert(sleeps == 2); // Initial LPI sample and final sideband settling delay.
    assert((bridge_writes() == std::vector<u32>{3, 2, 0}));
    assert(registers[0xe0000 / 4] == 0x80 && registers[0x87b8 / 4] == 0x21);
    for (unsigned selected_fault = 1; selected_fault <= 7; ++selected_fault) {
        clear(selected_fault);
        assert(iris_vpu33_2p_quiesce(&core) == -ETIMEDOUT);
        assert(bridge_writes().empty());
        assert(registers[0xe0000 / 4] == 0x80);
        assert(sleeps <= 2000 && reads < 5000);
    }
    clear();
    // Unrelated bits in all four sense registers must not block shutdown.
    for (u32 reg : {0x13300, 0x13304, 0x1330c, 0x13310}) registers[reg / 4] = 1;
    assert(iris_vpu33_2p_quiesce(&core) == 0 && bridge_writes().size() == 3);
}
CPP
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror -I "$here/iris-2p-stubs" -I "$iris" \
    "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Iris33 2P register contract, success, seven timeout faults and bounded retries: passed\n'
