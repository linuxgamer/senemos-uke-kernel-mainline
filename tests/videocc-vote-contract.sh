#!/usr/bin/env bash
# Compile the real voltage helper with host regulator/clock fault stubs.
set -Eeuo pipefail
helper=${1:?Pass uke-videocc-votes.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp "$helper" "$work/helper.c"
cat > "$work/vdd-level.h" <<'C'
#include <stdbool.h>
#include <stddef.h>
enum { VDD_NONE, VDD_MIN, VDD_LOWER_D1, VDD_LOWER, VDD_LOW,
       VDD_LOW_L0, VDD_LOW_L1, VDD_NOMINAL, VDD_NOMINAL_L1,
       VDD_HIGH, VDD_HIGH_L1, VDD_NUM };
static int vdd_corner[VDD_NUM];
struct device { void *of_node; };
struct clk_hw { const struct clk_init_data *init; };
struct clk_ops {
    int (*prepare)(struct clk_hw *);
    void (*unprepare)(struct clk_hw *);
    int (*pre_rate_change)(struct clk_hw *, unsigned long, unsigned long);
    int (*post_rate_change)(struct clk_hw *, unsigned long, unsigned long);
};
struct clk_init_data { const struct clk_ops *ops; };
struct clk_vdd_class { const char *class_name; const char *regulator_names[1]; };
struct clk_vdd_class_data {
    int num_rate_max;
    unsigned long *rate_max;
    struct clk_vdd_class *vdd_class;
    struct clk_vdd_class **vdd_classes;
    int num_vdd_classes;
};
struct clk_regmap { struct clk_hw hw; struct clk_vdd_class_data vdd_data; };
struct clock { struct clk_regmap clkr; };
struct qcom_cc_desc { struct clk_vdd_class **clk_regulators; size_t num_clk_regulators; };
#define DEFINE_VDD_REGULATORS(name, levels, count, corners) \
    struct clk_vdd_class name
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
C
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include "vdd-level.h"
static int fault, prepare_votes, unprepare_votes, regulator_gets, deinit,
           proxy_votes, proxy_unvotes, sync_calls, domain_gets;
struct regulator { int unused; };
static struct regulator bridge;
#define EPROBE_DEFER 517
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
static struct regulator *devm_regulator_get_optional(struct device *dev, const char *name) {
    (void)dev; assert(!strcmp(name,"vdd_mm_mxc")); ++domain_gets;
    if (fault == 8) return (struct regulator *)(intptr_t)-ENODEV;
    if (fault == 9) return (struct regulator *)(intptr_t)-EPROBE_DEFER;
    return &bridge;
}
static void (*cleanup)(void *);
static int clk_prepare_regmap(struct clk_hw *hw) { (void)hw; ++prepare_votes; return fault==1 ? -EIO : 0; }
static void clk_unprepare_regmap(struct clk_hw *hw) { (void)hw; ++unprepare_votes; }
static int pll_prepare(struct clk_hw *hw) { (void)hw; return fault==2 ? -ETIMEDOUT : 0; }
static int clk_pre_change_regmap(struct clk_hw *h, unsigned long a, unsigned long b) { (void)h; (void)a; (void)b; return 0; }
static int clk_post_change_regmap(struct clk_hw *h, unsigned long a, unsigned long b) { (void)h; (void)a; (void)b; return 0; }
static const struct clk_ops clk_alpha_pll_lucid_evo_ops = {.prepare=pll_prepare};
static const struct clk_ops clk_rcg2_shared_ops;
static const struct clk_init_data original_init;
static struct clock video_cc_pll0={.clkr.hw.init=&original_init},
                    video_cc_pll1={.clkr.hw.init=&original_init},
                    video_cc_mvs0_clk_src={.clkr.hw.init=&original_init},
                    video_cc_mvs1_clk_src={.clkr.hw.init=&original_init};
static struct qcom_cc_desc video_cc_sm7675_desc;
static int clk_regulator_init(struct device *d, const struct qcom_cc_desc *c) { (void)d; assert(c->num_clk_regulators==2); ++regulator_gets; return fault==3 ? -ENODEV : 0; }
static void clk_regulator_deinit(const struct qcom_cc_desc *c) { (void)c; ++deinit; }
static int clk_vdd_proxy_vote(struct device *d, const struct qcom_cc_desc *c) { (void)d; (void)c; ++proxy_votes; return fault==5 ? -EIO : 0; }
static int clk_vdd_proxy_unvote(struct device *d, const struct qcom_cc_desc *c) { (void)d; (void)c; ++proxy_unvotes; return fault==6 ? -EIO : 0; }
static int devm_add_action_or_reset(struct device *d, void (*action)(void *), void *arg) { (void)d; cleanup=action; if(fault==4) { action(arg); return -ENOMEM; } return 0; }
static bool of_device_is_compatible(void *node, const char *name) { return node && strcmp(name,"qcom,sm7675-videocc")==0; }
static int clk_sync_state(struct device *d) { (void)d; ++sync_calls; return fault==7 ? -EIO : 0; }
#define __DRIVERS_CLK_QCOM_VDD_LEVEL_H
C
# The test header is intentionally included once; the helper's include is empty.
printf '#pragma once\n' | cat - "$work/vdd-level.h" > "$work/header"
mv "$work/header" "$work/vdd-level.h"
printf '#include "helper.c"\n' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    struct device dev={.of_node=(void *)1};
    struct clk_hw hw={0};
    (void)vdd_corner;
    fault=1; assert(uke_video_pll_prepare(&hw)==-EIO && unprepare_votes==0);
    fault=2; assert(uke_video_pll_prepare(&hw)==-ETIMEDOUT && unprepare_votes==1);
    fault=0; assert(uke_video_pll_prepare(&hw)==0 && prepare_votes==3);
    fault=8; assert(uke_video_voltage_init(&dev)==-ENODEV && !regulator_gets && !proxy_votes);
    fault=9; assert(uke_video_voltage_init(&dev)==-EPROBE_DEFER && !regulator_gets && !proxy_votes);
    fault=3; assert(uke_video_voltage_init(&dev)==-ENODEV && proxy_votes==0);
    fault=4; assert(uke_video_voltage_init(&dev)==-ENOMEM && deinit==1 && proxy_votes==0);
    fault=5; assert(uke_video_voltage_init(&dev)==-EIO && !uke_video_proxy_active);
    cleanup(&dev); assert(deinit==2);
    fault=0; assert(uke_video_voltage_init(&dev)==0 && uke_video_proxy_active);
    assert(!strcmp(uke_video_mm.regulator_names[0],"vdd_mm"));
    assert(!strcmp(uke_video_mxc.regulator_names[0],"vdd_mxc"));
    assert(video_cc_pll0.clkr.vdd_data.vdd_class==&uke_video_mxc);
    assert(video_cc_mvs0_clk_src.clkr.vdd_data.num_vdd_classes==2);
    assert(video_cc_mvs1_clk_src.clkr.hw.init->ops->prepare==clk_prepare_regmap);
    assert(uke_video_mvs0_rates[VDD_LOWER_D1]==576000000);
    assert(uke_video_mvs0_rates[VDD_NOMINAL]==1332000000);
    assert(uke_video_mvs1_rates[VDD_LOWER]==1050000000);
    assert(uke_video_pll_rates[VDD_NOMINAL]==2000000000);
    assert(uke_video_pll_rates[VDD_HIGH_L1]==0);
    dev.of_node=0; uke_video_sync_state(&dev); assert(sync_calls==0 && uke_video_proxy_active);
    dev.of_node=(void *)1; fault=7; uke_video_sync_state(&dev); assert(uke_video_proxy_active);
    fault=6; uke_video_sync_state(&dev); assert(uke_video_proxy_active);
    fault=0; uke_video_sync_state(&dev); assert(!uke_video_proxy_active);
    int releases=proxy_unvotes; uke_video_sync_state(&dev); assert(proxy_unvotes==releases);
    cleanup(&dev); assert(deinit==3 && regulator_gets==4);
    assert(domain_gets==6);
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror -I "$work" "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual VIDEOCC votes, PLL unwind, init failures and proxy retry: passed\n'
