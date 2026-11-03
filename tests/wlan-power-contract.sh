#!/usr/bin/env bash
# Host faults against the actual ath11k AHB power functions; no hardware claim.
set -Eeuo pipefail
source_file=${1:?Pass the prepared ath11k ahb.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <cstring>
#define ARRAY_SIZE(a) int(sizeof(a)/sizeof((a)[0]))
struct node { bool uke = true; unsigned int supplies = 7; };
struct regulator { int index; };
regulator rails[] = {{0}, {1}, {2}};
struct regulator_bulk_data { const char *supply = nullptr; regulator *consumer = nullptr; };
// Power-sequence checks need storage independent of ath11k core memory.
// The separate lifetime fixture exercises delayed devres cleanup under ASan.
struct device { node *of_node; regulator_bulk_data managed[3]{}; };
struct ath11k_ahb {
    int *tgt_rproc = nullptr;
    regulator_bulk_data uke_regs[3];
    bool uke_supplies = false;
    int num_uke_regs_enabled = 0;
};
struct ath11k_base { device *dev; ath11k_ahb state; };
ath11k_ahb *ath11k_ahb_priv(ath11k_base *ab) { return &ab->state; }
int get_error = 0, enable_error_at = -1, disable_error_at = -1, boot_error = 0;
int gets = 0, enables = 0, boots = 0, shutdowns = 0, errors = 0;
bool of_device_is_compatible(node *n, const char *name) {
    return n->uke && !strcmp(name, "xiaomi,uke-wcn6750-wifi");
}
bool of_property_present(node *n, const char *property) {
    const char *names[] = {"vdd-cx-mx-supply", "vdd-1.8-xo-supply", "vdd-1.3-rfa-supply"};
    for (int i=0; i<3; ++i) if (!strcmp(property, names[i])) return n->supplies & (1U << i);
    return false;
}
int dev_err_probe(device *, int error, const char *) { return error; }
template<class... T> void ath11k_err(ath11k_base *, const char *, T...) { ++errors; }
int devm_regulator_bulk_get(device *, int count, regulator_bulk_data *regs) {
    assert(count == 3); ++gets;
    for (int i=0; i<count; ++i) regs[i].consumer = &rails[i];
    return get_error;
}
int devm_regulator_bulk_get_const(device *dev, int count,
                                 const regulator_bulk_data *input,
                                 regulator_bulk_data **output) {
    assert(count == 3 && input != dev->managed);
    std::memcpy(dev->managed, input, sizeof(dev->managed));
    *output = dev->managed;
    return devm_regulator_bulk_get(dev, count, *output);
}
int regulator_enable(regulator *rail) {
    assert(rail->index == enables); // Exact OEM forward sequence, without duplicate votes.
    if (rail->index == enable_error_at) return -EIO;
    ++enables; return 0;
}
int regulator_disable(regulator *rail) {
    assert(rail->index == enables-1); // Exact reverse cleanup, stopping on failure.
    if (rail->index == disable_error_at) return -EIO;
    --enables; return 0;
}
int rproc_boot(int *) { ++boots; return boot_error; }
void rproc_shutdown(int *) { ++shutdowns; }
CPP
awk '/^static int ath11k_ahb_uke_regulators/ { emit=1 } /^static void ath11k_ahb_init_qmi_ce_config/ { emit=0 } emit { print }' "$source_file"
cat <<'CPP'
int main() {
    node n; device d{&n}; ath11k_base ab{&d, {}};
    for (unsigned int missing : {1U, 2U, 4U}) {
        n.supplies = 7U ^ missing;
        assert(ath11k_ahb_uke_regulators(&ab) == -EINVAL && gets == 0);
    }
    n.supplies = 7; get_error = -517;
    assert(ath11k_ahb_uke_regulators(&ab) == -517 && !ab.state.uke_supplies);
    get_error = 0;
    assert(ath11k_ahb_uke_regulators(&ab) == 0 && ab.state.uke_supplies);
    for (int rail=0; rail<3; ++rail) {
        enable_error_at = rail;
        assert(ath11k_ahb_power_up(&ab) == -EIO && boots == 0 && enables == 0);
        assert(ab.state.num_uke_regs_enabled == 0);
    }
    enable_error_at = 2; disable_error_at = 1;
    assert(ath11k_ahb_power_up(&ab) == -EIO && boots == 0 && enables == 2);
    assert(ab.state.num_uke_regs_enabled == 2); // Partial cleanup cannot lose vote ownership.
    enable_error_at = -1; disable_error_at = -1;
    assert(ath11k_ahb_power_up(&ab) == 0 && enables == 3); // Resume the prefix without duplicate enable.
    ath11k_ahb_power_down(&ab, false);
    assert(enables == 0 && ab.state.num_uke_regs_enabled == 0);
    boot_error = -ETIMEDOUT;
    assert(ath11k_ahb_power_up(&ab) == -ETIMEDOUT && enables == 0);
    assert(ab.state.num_uke_regs_enabled == 0);
    boot_error = 0;
    for (int rail=0; rail<3; ++rail) {
        assert(ath11k_ahb_power_up(&ab) == 0 && enables == 3);
        disable_error_at = rail;
        ath11k_ahb_power_down(&ab, false);
        assert(ab.state.num_uke_regs_enabled == rail+1 && enables == rail+1);
        disable_error_at = -1;
        assert(ath11k_ahb_power_up(&ab) == 0 && enables == 3);
        ath11k_ahb_power_down(&ab, false);
        assert(ab.state.num_uke_regs_enabled == 0 && enables == 0);
    }
    ath11k_ahb_uke_regulators_off(&ab); // Already disabled: no unbalanced regulator call.
    n.uke = false; ab.state.uke_supplies = false; gets = 0;
    assert(ath11k_ahb_uke_regulators(&ab) == 0 && gets == 0);
    assert(ath11k_ahb_power_up(&ab) == 0 && enables == 0);
    ath11k_ahb_power_down(&ab, false);
    assert(enables == 0);
}
CPP
} > "$work/check.cpp"
"${CXX:-g++}" -include initializer_list -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter "$work/check.cpp" -o "$work/check"
"$work/check"
echo 'Uke WLAN OEM order, every rail fault, partial cleanup retry, provider defer and legacy path: passed'
