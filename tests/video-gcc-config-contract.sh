#!/usr/bin/env bash
# Compile the actual GCC probe and inject each configuration-write failure.
set -Eeuo pipefail
source_file=${1:?Pass the prepared gcc-cliffs.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
struct device {};
struct platform_device { device dev; };
struct regmap {};
static int gcc_cliffs_desc;
static bool gcc_cliffs_proxy_active;
static regmap map;
static int fault, writes, votes, registers, actions;
static constexpr unsigned BIT(unsigned n) { return 1u << n; }
static bool IS_ERR(regmap *) { return false; }
static int PTR_ERR(regmap *) { return -EIO; }
static int clk_regulator_init(device *, int *) { return 0; }
static void gcc_cliffs_vdd_release(void *) {}
static int devm_add_action_or_reset(device *, void (*)(void *), void *) {
    ++actions; return 0;
}
static regmap *qcom_cc_map(platform_device *, int *) { return &map; }
[[maybe_unused]] static int regmap_update_bits(regmap *m, unsigned reg, unsigned mask, unsigned value) {
    assert(m == &map && mask == BIT(0) && value == BIT(0));
    assert(writes < 2 && reg == (writes ? 0x32030u : 0x32004u));
    ++writes; return fault == writes ? -EREMOTEIO : 0;
}
static int clk_vdd_proxy_vote(device *, int *) { ++votes; return 0; }
static int qcom_cc_really_probe(device *, int *, regmap *) {
    assert(writes == 2); ++registers; return fault == 3 ? -EIO : 0;
}
static void dev_err(device *, const char *) {}
CPP
awk '/^static int gcc_cliffs_probe\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    platform_device p;
    for (fault=0; fault<=3; ++fault) {
        writes=votes=registers=actions=0; gcc_cliffs_proxy_active=false;
        const int rc=gcc_cliffs_probe(&p);
        assert(rc == (fault == 1 || fault == 2 ? -EREMOTEIO : fault == 3 ? -EIO : 0));
        assert(writes == (fault == 1 ? 1 : 2));
        assert(votes == (fault == 1 || fault == 2 ? 0 : 1));
        assert(registers == votes && gcc_cliffs_proxy_active == bool(votes));
        assert(actions == 1);
    }
    puts("Cliffs video AHB/XO gates, restricted writes and error propagation: PASS");
}
CPP
g++ -std=c++17 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
