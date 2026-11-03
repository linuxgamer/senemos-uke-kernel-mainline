#!/usr/bin/env bash
# Execute the actual IRQ thread with memory-only OPP/regmap stubs.
set -Eeuo pipefail
source_file=${1:?Pass the native icc-bwmon.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define BIT(n) (1U << (n))
#define BWMON_IRQ_ENABLE_MASK (BIT(1) | BIT(3))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define IRQ_HANDLED 1
#define F_THRESHOLD_HIGH 0
#define F_THRESHOLD_MED 1
typedef int irqreturn_t;
struct device { int unused; };
struct dev_pm_opp { unsigned int bw; int refs; };
struct icc_bwmon {
    struct device *dev;
    unsigned int target_kbps, current_kbps, max_bw_kbps, min_bw_kbps;
    bool retry_opp;
    void *regs[2];
};
static struct dev_pm_opp opps[] = {{100,0},{200,0},{300,0}};
static int vote_error, votes, errors, clears, enables;
static unsigned int applied, enabled_mask, thresholds[2];
static bool lookup_error;
static struct dev_pm_opp *dev_pm_opp_find_bw_ceil(struct device *d, unsigned int *bw, int index) {
    (void)d; assert(index == 0);
    if (lookup_error) return ERR_PTR(-ENODEV);
    for (unsigned int i=0;i<3;i++) if (opps[i].bw >= *bw) {
        *bw=opps[i].bw; opps[i].refs++; return &opps[i];
    }
    return ERR_PTR(-ERANGE);
}
static struct dev_pm_opp *dev_pm_opp_find_bw_floor(struct device *d, unsigned int *bw, int index) {
    (void)d; assert(index == 0);
    for (int i=2;i>=0;i--) if (opps[i].bw <= *bw) {
        *bw=opps[i].bw; opps[i].refs++; return &opps[i];
    }
    return ERR_PTR(-ERANGE);
}
static void dev_pm_opp_put(struct dev_pm_opp *opp) { assert(opp->refs>0); opp->refs--; }
static int dev_pm_opp_set_opp(struct device *d, struct dev_pm_opp *opp) {
    (void)d; votes++; if(vote_error) return vote_error; applied=opp->bw; return 0;
}
static void bwmon_set_threshold(struct icc_bwmon *b, void *reg, unsigned int bw) {
    (void)b; thresholds[(uintptr_t)reg]=bw;
}
static void bwmon_clear_counters(struct icc_bwmon *b, bool all) {(void)b; assert(!all); clears++;}
static void bwmon_clear_irq(struct icc_bwmon *b) {(void)b;}
static void bwmon_enable(struct icc_bwmon *b, unsigned int mask) {(void)b; enables++; enabled_mask=mask;}
static const char *dev_name(struct device *d) {(void)d; return "fixture";}
static void trace_qcom_bwmon_update(const char *name, unsigned int measured, unsigned int up, unsigned int down) {
    assert(!strcmp(name,"fixture")); (void)measured; assert(up>down);
}
#define dev_err_ratelimited(d, ...) ((void)(d), errors++)
C
awk '/^static irqreturn_t bwmon_intr_thread\(/ { emit=1 } /^static int bwmon_init_regmap\(/ { emit=0 } emit { print }' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void invoke(struct icc_bwmon *b) {
    assert(bwmon_intr_thread(0,b)==IRQ_HANDLED);
    for(unsigned int i=0;i<3;i++) assert(opps[i].refs==0);
}
int main(void) {
    struct device dev={0};
    struct icc_bwmon b={.dev=&dev,.target_kbps=250,.current_kbps=100,
        .min_bw_kbps=100,.max_bw_kbps=300,.regs={(void *)0,(void *)1}};
    applied=100; vote_error=-EIO;
    invoke(&b);
    assert(b.current_kbps==100 && applied==100);
    assert(votes==1 && errors==1);
    assert(thresholds[0]==301 && thresholds[1]==200 && enabled_mask==BIT(1));
    invoke(&b); // An unchanged requested target must still retry a failed vote.
    assert(b.current_kbps==100 && votes==2 && errors==2);
    vote_error=0; invoke(&b);
    assert(b.current_kbps==300 && applied==300 && votes==3);
    invoke(&b); assert(votes==3);
    b.target_kbps=50; vote_error=-517; invoke(&b);
    assert(b.current_kbps==300 && applied==300 && votes==4 && errors==3);
    assert(thresholds[0]==101 && thresholds[1]==100 && enabled_mask==BIT(3));
    vote_error=0; invoke(&b); assert(b.current_kbps==100 && applied==100 && votes==5);
    b.target_kbps=150; invoke(&b);
    assert(b.current_kbps==200 && applied==200 && enabled_mask==BWMON_IRQ_ENABLE_MASK);
    b.target_kbps=999; invoke(&b); assert(b.current_kbps==300 && applied==300);
    int prior_votes=votes, prior_clears=clears, prior_enables=enables;
    b.target_kbps=150; lookup_error=true; invoke(&b);
    assert(b.current_kbps==300 && votes==prior_votes && clears==prior_clears && enables==prior_enables);
    lookup_error=false; b.current_kbps=100; b.target_kbps=250; applied=100; vote_error=-EIO;
    prior_votes=votes; invoke(&b);
    b.target_kbps=100; vote_error=0; invoke(&b);
    assert(votes==prior_votes+2 && !b.retry_opp && b.current_kbps==100 && applied==100);
    puts("Actual BWMON IRQ thread: failed votes, return-to-applied retry, successful commit, OPP bounds/refcounts and IRQ rearm passed; host only");
    return 0;
}
C
${CC:-cc} -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$work/check.c" -o "$work/check"
"$work/check"
