#!/usr/bin/env bash
# Actual IRQ and threshold functions; host-only MMIO/error/byte-unit ledgers.
set -Eeuo pipefail
source_file=${1:?Pass prepared icc-bwmon.c}
mode=${2:-all}
case $mode in all|irq|units) ;; *) exit 2;; esac
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
if grep -q '^static const struct icc_bwmon_data sm7675_' "$source_file"; then
    printf '#define HAVE_SM7675_DATA 1\n' > "$work/check.c"
else
    printf '#define HAVE_SM7675_DATA 0\n' > "$work/check.c"
fi
cat >> "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t u64;
typedef uint8_t u8;
typedef int irqreturn_t;
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define IRQ_WAKE_THREAD 2
#define BIT(n) (1U<<(n))
#define BWMON_IRQ_ENABLE_MASK (BIT(1)|BIT(3))
#define MSEC_PER_SEC 1000
#define F_IRQ_STATUS 0
#define F_ZONE0_MAX 1
#define SZ_64K 65536U
#define BWMON_HAS_GLOBAL_IRQ 1U
#define BWMON_NEEDS_FORCE_CLEAR 2U
struct regmap_config { unsigned int unused; };
struct reg_field { unsigned int unused; };
#if HAVE_SM7675_DATA
static const struct regmap_config sdm845_cpu_bwmon_regmap_cfg,sdm845_llcc_bwmon_regmap_cfg;
static const struct reg_field sdm845_cpu_bwmon_reg_fields[1],sdm845_llcc_bwmon_reg_fields[1];
#endif
struct regmap_field { unsigned int id; };
struct icc_bwmon_data { unsigned int sample_ms,count_unit_kb,count_unit_bytes; u8 zone1_thres_count,zone3_thres_count; unsigned int quirks; const struct regmap_config *regmap_cfg,*global_regmap_cfg; const struct reg_field *regmap_fields,*global_regmap_fields; };
struct icc_bwmon {
    void *dev; const struct icc_bwmon_data *data; struct regmap_field *regs[5];
    unsigned int target_kbps,current_kbps;
};
static unsigned int status,count,disables,enables,clears,irq_clears,errors,mask,threshold;
static int fail_read=-1;
static bool enabled=true;
static u64 div_u64(u64 n,unsigned int d) { assert(d); return n/d; }
#define mult_frac(x,n,d) (((u64)(x)*(n))/(d))
static unsigned int get_bitmask_order(unsigned int v) { assert(v); return 32-__builtin_clz(v); }
static int regmap_field_read(struct regmap_field *field,unsigned int *value) {
    if((int)field->id==fail_read) return -EIO;
    assert(field->id<5); *value=field->id?count:status; return 0;
}
static int regmap_field_write(struct regmap_field *field,unsigned int value) { (void)field; threshold=value; return 0; }
static void bwmon_disable(struct icc_bwmon *b) { (void)b; enabled=false; disables++; }
static void bwmon_enable(struct icc_bwmon *b,unsigned int value) { (void)b; assert(value); enabled=true; enables++; mask=value; }
static void bwmon_clear_counters(struct icc_bwmon *b,bool all) { (void)b; assert(!all); clears++; }
static void bwmon_clear_irq(struct icc_bwmon *b) { (void)b; irq_clears++; }
#define dev_err_ratelimited(d,...) ((void)(d),errors++)
C
awk '/^static (unsigned int|void|irqreturn_t) bwmon_(kbps_to_count|count_to_kbps|set_threshold|intr)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.c"
if grep -q '^static const struct icc_bwmon_data sm7675_' "$source_file"; then
    awk '/^static const struct icc_bwmon_data sm7675_/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$source_file" >> "$work/check.c"
fi
cat >> "$work/check.c" <<'C'
static void reset(void) { disables=enables=clears=irq_clears=errors=0; mask=0; fail_read=-1; enabled=true; }
int main(int argc,char **argv) {
    assert(argc==2);
    struct regmap_field fields[]={{0},{1},{2},{3},{4}};
    struct icc_bwmon_data data={.sample_ms=4,.count_unit_kb=64,.count_unit_bytes=65536};
#if HAVE_SM7675_DATA
    data=sm7675_llcc_bwmon_data;
    assert(data.sample_ms==4 && data.count_unit_bytes==SZ_64K && !data.count_unit_kb);
    assert(data.zone1_thres_count==16 && data.zone3_thres_count==1 && data.quirks==BWMON_NEEDS_FORCE_CLEAR);
    assert(data.regmap_fields==sdm845_llcc_bwmon_reg_fields && data.regmap_cfg==&sdm845_llcc_bwmon_regmap_cfg);
    assert(sm7675_cpu_bwmon_data.sample_ms==4 && sm7675_cpu_bwmon_data.count_unit_bytes==SZ_64K);
    assert(!sm7675_cpu_bwmon_data.count_unit_kb && sm7675_cpu_bwmon_data.quirks==BWMON_HAS_GLOBAL_IRQ);
    assert(sm7675_cpu_bwmon_data.regmap_fields==sdm845_cpu_bwmon_reg_fields && sm7675_cpu_bwmon_data.regmap_cfg==&sdm845_cpu_bwmon_regmap_cfg);
#endif
    struct icc_bwmon b={.data=&data,.target_kbps=123,.current_kbps=456,.regs={fields,fields+1,fields+2,fields+3,fields+4}};
    if(strcmp(argv[1],"units")) {
        reset(); status=BIT(3); fail_read=F_ZONE0_MAX+3;
        assert(bwmon_intr(0,&b)==IRQ_HANDLED);
        assert(enabled && disables==1 && enables==1 && clears==1 && irq_clears==1 && errors==1);
        assert(mask==BWMON_IRQ_ENABLE_MASK && b.target_kbps==123 && b.current_kbps==456);
        reset(); status=BIT(1); fail_read=F_ZONE0_MAX+1;
        assert(bwmon_intr(0,&b)==IRQ_HANDLED && enabled && enables==1 && b.target_kbps==123);
        reset(); status=BWMON_IRQ_ENABLE_MASK; fail_read=0;
        assert(bwmon_intr(0,&b)==IRQ_NONE && !disables && !enables && !clears);
        for(unsigned int s=0;s<16;s++) if(!(s&BWMON_IRQ_ENABLE_MASK)) {
            reset(); status=s;
            assert(bwmon_intr(0,&b)==IRQ_NONE && !disables && !enables && !clears);
        }
    }
    if(strcmp(argv[1],"irq")) {
        for(count=0;count<4096;count++) {
            reset(); status=BIT(3);
            assert(bwmon_intr(0,&b)==IRQ_WAKE_THREAD && !enabled && !enables && !clears);
            assert(b.target_kbps==(count+1)*16384U && b.current_kbps==456);
        }
        for(unsigned int i=0;i<5;i++) {
            unsigned int bw=(unsigned int[]){0,16383,16384,2188000,16896000}[i];
            bwmon_set_threshold(&b,fields,bw);
            assert(threshold==(uint64_t)bw*4/65536);
        }
        data.count_unit_bytes=0;
        for(unsigned int unit=64;unit<=1024;unit*=16) {
            data.count_unit_kb=unit;
            for(count=0;count<4096;count+=31) {
                reset(); status=BIT(1);
                assert(bwmon_intr(0,&b)==IRQ_WAKE_THREAD);
                assert(b.target_kbps==(count+1)*unit*250U);
            }
            bwmon_set_threshold(&b,fields,2188000);
            assert(threshold==(2188000/unit)*4/1000);
        }
    }
    puts("Actual BWMON counter/threshold: decimal byte units, all 12-bit counts, legacy scaling, owned read-fault rearm and shared-IRQ refusals passed; host only");
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check" "$mode"
