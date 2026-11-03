#!/usr/bin/env bash
# Execute the provider-owned helper with identity, regmap and readback faults.
set -Eeuo pipefail
source_file=${1:?Pass the prepared videocc-sm8550.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
#define BIT(n) (1u << (n))
#define IS_ERR(p) ((intptr_t)(p) < 0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
struct device { const char *of_node; };
struct clk_hw { int id; };
struct clk { int id; };
static struct { u32 halt_reg; struct { void *regmap; struct clk_hw hw; } clkr; }
    video_cc_mvs0c_clk = {0x8064, {NULL, {0}}};
static struct device consumer = {"qcom,sm7675-iris"}, provider = {"qcom,sm7675-videocc"};
static struct clk clock;
static struct clk_hw other;
static int fault, gets, releases, reads, writes, delays;
static bool uke = true, substituted, missing_provider;
static u32 cbcr;
static bool of_machine_is_compatible(const char *s) { assert(!strcmp(s,"xiaomi,uke")); return uke; }
static bool of_device_is_compatible(const char *node, const char *s) { return !strcmp(node,s); }
static struct clk *clk_get(struct device *dev, const char *name) {
    assert(dev == &consumer && !strcmp(name,"core")); ++gets;
    return fault == 1 ? (struct clk *)(intptr_t)-EPROBE_DEFER : &clock;
}
static struct clk_hw *__clk_get_hw(struct clk *clk) {
    assert(clk == &clock); return substituted ? &other : &video_cc_mvs0c_clk.clkr.hw;
}
static struct device *clk_hw_get_dev(struct clk_hw *hw) { (void)hw; return missing_provider ? NULL : &provider; }
static void clk_put(struct clk *clk) { assert(clk == &clock); ++releases; }
static int regmap_update_bits(void *map, u32 reg, u32 mask, u32 value) {
    assert(map == video_cc_mvs0c_clk.clkr.regmap && reg == 0x8064 && mask == 0x6000);
    assert(value == mask || value == 0); ++writes;
    if (fault == 2) return -EREMOTEIO;
    if (fault != 4) cbcr = (cbcr & ~mask) | value;
    return 0;
}
static int regmap_read(void *map, u32 reg, u32 *value) {
    assert(map == video_cc_mvs0c_clk.clkr.regmap && reg == 0x8064); ++reads;
    *value = cbcr; return fault == 3 ? -EIO : 0;
}
static void udelay(int n) { assert(n == 1); ++delays; }
C
# Linux probe deferral has no libc errno counterpart.
sed -i '/#define BIT/i #define EPROBE_DEFER 517' "$work/check.c"
awk '/^int qcom_uke_videocc_set_retention\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void reset(void) {
    fault = gets = releases = reads = writes = delays = 0; uke=true;
    substituted=missing_provider=false;
    consumer.of_node="qcom,sm7675-iris"; provider.of_node="qcom,sm7675-videocc";
    cbcr=0x80000001;
}
int main(void) {
    reset(); uke=false;
    assert(qcom_uke_videocc_set_retention(&consumer,true)==-ENODEV && !gets && !writes);
    reset(); consumer.of_node="qcom,sm8650-iris";
    assert(qcom_uke_videocc_set_retention(&consumer,true)==-ENODEV && !gets && !writes);
    reset(); fault=1;
    assert(qcom_uke_videocc_set_retention(&consumer,true)==-EPROBE_DEFER && gets==1 && !releases);
    for (int refusal=0; refusal<3; ++refusal) {
        reset(); substituted=refusal==0; missing_provider=refusal==1;
        if (refusal==2) provider.of_node="qcom,sm8650-videocc";
        assert(qcom_uke_videocc_set_retention(&consumer,true)==-ENODEV && releases==1 && !writes);
    }
    for (int failure=2; failure<=4; ++failure) {
        reset(); fault=failure;
        assert(qcom_uke_videocc_set_retention(&consumer,true)==
               (failure==2 ? -EREMOTEIO : failure==3 ? -EIO : -EACCES));
        assert(releases==1 && writes==1 && reads==(failure!=2));
    }
    reset();
    assert(qcom_uke_videocc_set_retention(&consumer,true)==0 && cbcr==0x80006001);
    assert(qcom_uke_videocc_set_retention(&consumer,false)==0 && cbcr==0x80000001);
    assert(gets==2 && releases==2 && reads==2 && delays==2);
    puts("VIDEOCC retention identity, settling, masked readback and regmap failures: PASS");
}
C
cc -std=gnu11 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
