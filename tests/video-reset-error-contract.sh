#!/usr/bin/env bash
# Actual shared Qualcomm reset code with transport and callback faults.
set -Eeuo pipefail
qcom=${1:?Pass the prepared drivers/clk/qcom directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#define BIT(n) (1u << (n))
#define EXPORT_SYMBOL_GPL(n)
typedef uint32_t u32;
struct reset_controller_dev;
struct reset_control_ops {
    int (*reset)(struct reset_controller_dev *, unsigned long);
    int (*assert)(struct reset_controller_dev *, unsigned long);
    int (*deassert)(struct reset_controller_dev *, unsigned long);
};
struct qcom_reset_map { unsigned reg, bit, udelay, bitmask; };
struct qcom_reset_controller;
struct reset_controller_dev { const struct reset_control_ops *ops; struct qcom_reset_controller *owner; };
struct qcom_reset_controller { const struct qcom_reset_map *reset_map; void *regmap; struct reset_controller_dev rcdev; };
#define to_qcom_reset_controller(r) ((r)->owner)
static int update_error, read_error, assert_error, deassert_error;
static unsigned updates, reads, sleeps, asserts, deasserts, delay;
static u32 last_mask, last_value;
static int regmap_update_bits(void *map, unsigned reg, u32 mask, u32 value) {
    (void)map; assert(reg == 0x8064); ++updates; last_mask = mask; last_value = value;
    return update_error;
}
static int regmap_read(void *map, unsigned reg, u32 *value) {
    (void)map; assert(reg == 0x8064); ++reads; *value = last_value; return read_error;
}
static void fsleep(unsigned n) { ++sleeps; delay = n; }
C
printf '#undef assert\n' >> "$work/check.c"
sed '/^#include /d' "$qcom/reset.c" >> "$work/check.c"
printf '#include <assert.h>\n' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int fake_assert(struct reset_controller_dev *dev, unsigned long id) {
    (void)dev; assert(id == 0); ++asserts; return assert_error;
}
static int fake_deassert(struct reset_controller_dev *dev, unsigned long id) {
    (void)dev; assert(id == 0); ++deasserts; return deassert_error;
}
int main(void) {
    struct qcom_reset_map map = {0x8064, 2, 400, 0};
    struct qcom_reset_controller controller = {.reset_map = &map};
    controller.rcdev = (struct reset_controller_dev){&qcom_reset_ops, &controller};
    assert(qcom_reset_assert(&controller.rcdev, 0) == 0 && updates == 1 && reads == 1);
    assert(last_mask == 4 && last_value == 4);
    assert(qcom_reset_deassert(&controller.rcdev, 0) == 0 && last_value == 0);
    map.bitmask = 0x30;
    assert(qcom_reset_assert(&controller.rcdev, 0) == 0 && last_mask == 0x30 && last_value == 0x30);
    update_error = -EREMOTEIO; unsigned old_reads = reads;
    assert(qcom_reset_assert(&controller.rcdev, 0) == -EREMOTEIO && reads == old_reads);
    update_error = 0; read_error = -EIO;
    assert(qcom_reset_deassert(&controller.rcdev, 0) == -EIO);
    read_error = 0;
    const struct reset_control_ops mock_ops = {.assert = fake_assert, .deassert = fake_deassert};
    controller.rcdev.ops = &mock_ops; assert_error = -EREMOTEIO;
    assert(qcom_reset(&controller.rcdev, 0) == -EREMOTEIO && !sleeps && !deasserts);
    assert_error = 0; deassert_error = -EACCES;
    assert(qcom_reset(&controller.rcdev, 0) == -EACCES && sleeps == 1 && deasserts == 1 && delay == 400);
    deassert_error = 0; map.udelay = 0;
    assert(qcom_reset(&controller.rcdev, 0) == 0 && sleeps == 2 && delay == 1);
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual Qualcomm reset: mask/default delay and assert/deassert/regmap error propagation passed\n'
